import CryptoKit
import Foundation
import VMPaneControl
import VMPaneCore
import os

/// Clipboard contents as VMPane moves them: text (also formatted, as HTML and RTF), a PNG image, a list of files.
public struct ClipboardContent: Equatable, Sendable {
    public var text: String?
    /// Formatted text: an HTML document and an RTF document (either or both, with `text` alongside).
    public var html: String?
    public var rtf: Data?
    public var png: Data?
    /// Paths on the side the content comes from (guest paths from the guest, host file URLs' paths on the Mac).
    public var files: [String]

    public init(text: String? = nil, html: String? = nil, rtf: Data? = nil, png: Data? = nil, files: [String] = []) {
        self.text = text
        self.html = html
        self.rtf = rtf
        self.png = png
        self.files = files
    }

    public var isEmpty: Bool { text == nil && html == nil && rtf == nil && png == nil && files.isEmpty }

    /// Without the formatting (the VM's "Keep text formatting" off, or an agent without `clipboard.rich`).
    var plain: ClipboardContent {
        var content = self
        (content.html, content.rtf) = (nil, nil)
        return content
    }

    /// Identifies content across both directions, so what one side just received is not sent back (no ping-pong).
    /// Formatting is left out: a side that loses it on the way back still sees the same content.
    var fingerprint: Data {
        var hash = SHA256()
        if let text { hash.update(data: Data("t\(text)".utf8)) }
        if let png { hash.update(data: png) }
        for file in files { hash.update(data: Data("f\((file as NSString).lastPathComponent)".utf8)) }
        return Data(hash.finalize())
    }
}

/// The Mac's pasteboard as the bridge sees it: `NSPasteboard.general` in the helper app, a fake in tests.
public protocol HostPasteboard: Sendable {
    func changeCount() async -> Int
    func read() async -> ClipboardContent
    /// Replaces the pasteboard; `files` are host paths. Returns the change count after writing.
    func write(_ content: ClipboardContent) async -> Int
}

/// The guest agent's clipboard (`clipboard.get` / `clipboard.set`; macOS and Windows guests).
enum AgentClipboard {
    /// The types to ask an agent for: formatted text only from one with `clipboard.rich`.
    static func types(rich: Bool) -> [AgentClipboardType] { [.text, .png, .files] + (rich ? [.html, .rtf] : []) }

    static func get(_ connection: AgentConnection, types: [AgentClipboardType]) async throws -> ClipboardContent {
        let names = AgentConnection.StreamNames(inbound: { result in
            guard case .array(let items)? = result["items"] else { return [] }
            return items.compactMap { $0["stream"]?.intValue.flatMap { UInt32(exactly: $0) } }
        })
        let call = try await connection.call(
            AgentMethod.clipboardGet, RPCParams.encode(AgentClipboardGetParams(types: types)).get(), timeout: .seconds(30), streams: names)
        defer { for stream in call.inbound.values { stream.discard() } }  // any the guest named but we do not read
        let items = try RPCParams.decode(AgentClipboardContents.self, from: call.result).get().items
        var content = ClipboardContent()
        for item in items {
            switch item.type {
            case .files: content.files = item.files ?? []
            case .text, .png, .html, .rtf:
                guard let stream = item.stream.flatMap({ call.inbound[$0] }) else { continue }
                let data = try await stream.collect(limit: Int(AgentLimits.maxClipboardBytes))
                switch item.type {
                case .text: content.text = String(bytes: data, encoding: .utf8)
                case .html: content.html = String(bytes: data, encoding: .utf8)
                case .rtf: content.rtf = data
                default: content.png = data
                }
            }
        }
        return content
    }

    /// Sets the guest clipboard to `content` (text, formatted text and PNG; a file list names guest paths).
    static func set(_ connection: AgentConnection, _ content: ClipboardContent) async throws {
        var items: [AgentClipboardItem] = []
        var payloads: [(UInt32, Data)] = []
        let byStream: [(AgentClipboardType, Data?)] = [
            (.text, content.text.map { Data($0.utf8) }), (.html, content.html.map { Data($0.utf8) }), (.rtf, content.rtf),
            (.png, content.png),
        ]
        for (type, data) in byStream {
            guard let data else { continue }
            guard data.count <= AgentLimits.maxClipboardBytes else { throw RPCError(.invalidParams, "clipboard content over 32 MiB") }
            let stream = try await connection.openOutbound()
            items.append(AgentClipboardItem(type: type, stream: stream, size: UInt64(data.count)))
            payloads.append((stream, data))
        }
        if !content.files.isEmpty { items.append(AgentClipboardItem(type: .files, files: content.files)) }
        let call = try await connection.start(AgentMethod.clipboardSet, RPCParams.encode(AgentClipboardContents(items: items)).get())
        for (stream, data) in payloads {
            var offset = 0
            while offset < data.count {
                let end = min(offset + Int(AgentLimits.maxChunk), data.count)
                try await connection.send(data.subdata(in: offset..<end), on: stream)
                offset = end
            }
            try await connection.end(stream)
        }
        _ = try await connection.response(call, timeout: .seconds(30))
    }
}

/// A VM's clipboard sharing through the guest agent (macOS and Windows guests; Linux guests share theirs through
/// SPICE). Both directions follow the VM's `clipboard.mode` and only while its window is the key window: the
/// guest neither reads the Mac's clipboard nor replaces it while the user works elsewhere. A guest change seen
/// while unfocused is fetched when the window gets focus. Files copied in the guest are pulled into a staging
/// folder (`HostFileSink.clipboardStaging`, one copy at a time) and put on the pasteboard as those files, so
/// Cmd-V in Finder pastes them where it is pressed; files copied on the Mac are put in the guest first (`push`)
/// and its clipboard gets them as files there.
public actor ClipboardBridge {
    static let log = Logger(subsystem: VMPane.SigningIdentifier.helper, category: "clipboard")

    private let pasteboard: HostPasteboard
    private let staging: URL
    private let pull: @Sendable (AgentConnection, [String], HostFileSink, String) async throws -> [URL]
    private let push: @Sendable (AgentConnection, [String]) async throws -> [String]
    private var mode: ClipboardConfig.Mode
    /// Formatted text moves too (the VM's "Keep text formatting", and an agent with `clipboard.rich`).
    private var rich = false
    private var focused = false
    private var connection: AgentConnection?
    private var seenChangeCount: Int?
    private var lastApplied: Data?
    /// Files from the guest's clipboard share one budget per hour (`HostFileSink`'s caps), so a guest that keeps
    /// changing its clipboard cannot keep the Mac copying.
    private var fileBudget: (sink: HostFileSink, since: ContinuousClock.Instant)?
    private var guestChangedWhileAway = false
    private var poller: Task<Void, Never>?
    /// Bumped by every focus change: work started under an older focus does not start a poller.
    private var focusGeneration = 0
    /// A fetch from the guest is running; another change meanwhile is fetched once it ends.
    private var fetching = false
    private var fetchAgain = false
    /// An offer to the guest is running (files can take a while to go in): the next poll waits for it.
    private var offering = false
    /// Bumped by every write of the guest's clipboard to the Mac's: an offer that took long does not undo one.
    private var guestWrites = 0

    /// `pull(connection, guestPaths, sink, prefix)` copies guest files and folders into `sink` below `prefix` and
    /// returns where they landed; `push(connection, hostPaths)` copies host files and folders into the guest and
    /// returns their guest paths.
    public init(
        pasteboard: HostPasteboard, mode: ClipboardConfig.Mode, staging: URL,
        pull: @escaping @Sendable (AgentConnection, [String], HostFileSink, String) async throws -> [URL],
        push: @escaping @Sendable (AgentConnection, [String]) async throws -> [String]
    ) {
        self.pasteboard = pasteboard
        self.mode = mode
        self.staging = staging
        self.pull = pull
        self.push = push
    }

    public func setMode(_ mode: ClipboardConfig.Mode) { self.mode = mode }

    public func setRich(_ rich: Bool) { self.rich = rich }

    /// The agent's connection (nil when it went away).
    public func attach(_ connection: AgentConnection?) {
        self.connection = connection
    }

    /// The VM window became (or stopped being) the key window: sharing runs only while it is.
    public func setFocused(_ focused: Bool) async {
        self.focused = focused
        focusGeneration += 1
        let generation = focusGeneration
        poller?.cancel()
        poller = nil
        guard focused else { return }
        if guestChangedWhileAway {
            guestChangedWhileAway = false
            await fetchFromGuest()
        }
        await offerToGuest()
        guard generation == focusGeneration else { return }  // focus moved on meanwhile
        // macOS posts no pasteboard notification: look four times a second while focused.
        poller = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                await self?.offerToGuest()
            }
        }
    }

    public func stop() {
        poller?.cancel()
        poller = nil
        connection = nil
    }

    /// `clipboard.changed` from the guest.
    public func guestChanged() async {
        guard mode.receivesFromGuest else { return }
        guard focused else {
            guestChangedWhileAway = true
            return
        }
        await fetchFromGuest()
    }

    /// Sends the Mac's clipboard to the guest if it changed since last seen (and is not what the guest just gave).
    func offerToGuest() async {
        // A change made while unfocused (or with sending off) stays unseen, so it is offered once allowed.
        guard focused, mode.sendsToGuest, !offering, let connection else { return }
        offering = true
        defer { offering = false }
        let count = await pasteboard.changeCount()
        guard count != seenChangeCount else { return }
        seenChangeCount = count
        var content = await pasteboard.read()
        if !rich { content = content.plain }
        guard !content.isEmpty, content.fingerprint != lastApplied else { return }
        lastApplied = content.fingerprint
        if !content.files.isEmpty {
            // Files copied in Finder go into the guest first; its clipboard gets them as files, their names as text
            // (not Finder's icon image). Too many or too large: the names only.
            let files = content.files
            content = ClipboardContent(text: content.text)
            let (generation, writes) = (focusGeneration, guestWrites)
            do {
                content.files = try await push(connection, files)
            } catch {
                Self.log.notice("files copied on the Mac stay there: \(String(describing: error), privacy: .public)")
            }
            // Meanwhile the window went to the back, or something copied in the guest came over: that stays.
            guard !content.isEmpty, focused, generation == focusGeneration, writes == guestWrites else { return }
        }
        do {
            try await AgentClipboard.set(connection, content)
        } catch {
            Self.log.notice("the guest did not take the clipboard: \(String(describing: error), privacy: .public)")
        }
    }

    private func fetchFromGuest() async {
        guard !fetching else {
            fetchAgain = true
            return
        }
        fetching = true
        defer { fetching = false }
        repeat {
            fetchAgain = false
            await fetchOnce()
        } while fetchAgain && focused
    }

    private func fetchOnce() async {
        guard let connection else { return }
        var staged: URL?
        do {
            let before = await pasteboard.changeCount()
            var content = try await AgentClipboard.get(connection, types: AgentClipboard.types(rich: rich))
            guard !content.isEmpty, content.fingerprint != lastApplied else { return }
            if !content.files.isEmpty {
                let copy = staging.appendingPathComponent(String(Int(Date().timeIntervalSince1970 * 1000)), isDirectory: true)
                staged = copy
                content.files = try await pullFiles(content.files, into: copy, on: connection)
            }
            // A copy made on the Mac meanwhile (files can take a while), or the window gone to the back: the Mac's
            // clipboard stays as it is; the guest's change is fetched again on the next focus.
            guard focused, await pasteboard.changeCount() == before else {
                if !focused { guestChangedWhileAway = true }
                if let staged { try? FileManager.default.removeItem(at: staged) }
                return
            }
            lastApplied = content.fingerprint
            seenChangeCount = await pasteboard.write(content)
            guestWrites += 1
            // The staged copies before this one go: the pasteboard no longer names them.
            let all = (try? FileManager.default.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)) ?? []
            for folder in all where folder.lastPathComponent != staged?.lastPathComponent {
                try? FileManager.default.removeItem(at: folder)
            }
        } catch {
            if let staged { try? FileManager.default.removeItem(at: staged) }
            Self.log.notice("the guest's clipboard could not be fetched: \(String(describing: error), privacy: .public)")
        }
    }

    /// Copies the guest's files and folders into staging folder `copy`; returns their host paths.
    private func pullFiles(_ paths: [String], into copy: URL, on connection: AgentConnection) async throws -> [String] {
        if fileBudget.map({ ContinuousClock.now - $0.since > .seconds(3600) }) ?? true {
            fileBudget = (HostFileSink(root: staging), .now)
        }
        guard let sink = fileBudget?.sink else { return [] }
        return try await pull(connection, paths, sink, copy.lastPathComponent + "/").map(\.path)
    }
}
