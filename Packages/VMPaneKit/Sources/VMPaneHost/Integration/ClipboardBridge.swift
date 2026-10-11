import CryptoKit
import Foundation
import VMPaneControl
import VMPaneCore
import os

/// Clipboard contents as VMPane moves them: text, a PNG image, a list of files.
public struct ClipboardContent: Equatable, Sendable {
    public var text: String?
    public var png: Data?
    /// Paths on the side the content comes from (guest paths from the guest, host file URLs' paths on the Mac).
    public var files: [String]

    public init(text: String? = nil, png: Data? = nil, files: [String] = []) {
        self.text = text
        self.png = png
        self.files = files
    }

    public var isEmpty: Bool { text == nil && png == nil && files.isEmpty }

    var types: [AgentClipboardType] {
        (text != nil ? [.text] : []) + (png != nil ? [.png] : []) + (files.isEmpty ? [] : [.files])
    }

    /// Identifies content across both directions, so what one side just received is not sent back (no ping-pong).
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

/// The guest agent's clipboard (`clipboard.get` / `clipboard.set`; macOS guests).
enum AgentClipboard {
    static func get(_ connection: AgentConnection, types: [AgentClipboardType]) async throws -> ClipboardContent {
        let names = AgentConnection.StreamNames(inbound: { result in
            guard case .array(let items)? = result["items"] else { return [] }
            return items.compactMap { $0["stream"]?.intValue.map(UInt32.init) }
        })
        let call = try await connection.call(
            AgentMethod.clipboardGet, RPCParams.encode(AgentClipboardGetParams(types: types)).get(), timeout: .seconds(30), streams: names)
        let items = try RPCParams.decode(AgentClipboardContents.self, from: call.result).get().items
        var content = ClipboardContent()
        for item in items {
            switch item.type {
            case .files: content.files = item.files ?? []
            case .text, .png:
                guard let stream = item.stream.flatMap({ call.inbound[$0] }) else { continue }
                let data = try await stream.collect(limit: Int(AgentLimits.maxClipboardBytes))
                if item.type == .text { content.text = String(bytes: data, encoding: .utf8) } else { content.png = data }
            }
        }
        return content
    }

    /// Sets the guest clipboard to `content` (text and PNG; a file list names guest paths).
    static func set(_ connection: AgentConnection, _ content: ClipboardContent) async throws {
        var items: [AgentClipboardItem] = []
        var payloads: [(UInt32, Data)] = []
        for (type, data) in [(AgentClipboardType.text, content.text.map { Data($0.utf8) }), (.png, content.png)] {
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

/// A VM's clipboard sharing through the guest agent (macOS guests; Linux and Windows guests share theirs through
/// SPICE). Both directions follow the VM's `clipboard.mode` and only while its window is the key window: the
/// guest neither reads the Mac's clipboard nor replaces it while the user works elsewhere. A guest change seen
/// while unfocused is fetched when the window gets focus. Files copied in the guest are pulled into
/// `~/Downloads/VMPane/<vm>/` (`HostFileSink`) and put on the pasteboard as those files.
public actor ClipboardBridge {
    static let log = Logger(subsystem: VMPane.SigningIdentifier.helper, category: "clipboard")

    private let pasteboard: HostPasteboard
    private let downloads: URL
    private let pull: @Sendable (AgentConnection, String, FileHandle, HostFileSink) async throws -> Void
    private var mode: ClipboardConfig.Mode
    private var focused = false
    private var connection: AgentConnection?
    private var seenChangeCount: Int?
    private var lastApplied: Data?
    private var guestChangedWhileAway = false
    private var poller: Task<Void, Never>?
    /// Bumped by every focus change: work started under an older focus does not start a poller.
    private var focusGeneration = 0
    /// A fetch from the guest is running; another change meanwhile is fetched once it ends.
    private var fetching = false
    private var fetchAgain = false

    /// `pull(connection, guestPath, into, sink)` copies a guest file into an open host file.
    public init(
        pasteboard: HostPasteboard, mode: ClipboardConfig.Mode, downloads: URL,
        pull: @escaping @Sendable (AgentConnection, String, FileHandle, HostFileSink) async throws -> Void
    ) {
        self.pasteboard = pasteboard
        self.mode = mode
        self.downloads = downloads
        self.pull = pull
    }

    public func setMode(_ mode: ClipboardConfig.Mode) { self.mode = mode }

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
        guard focused, mode.sendsToGuest, let connection else { return }
        let count = await pasteboard.changeCount()
        guard count != seenChangeCount else { return }
        seenChangeCount = count
        var content = await pasteboard.read()
        content.files = []  // files go to the guest by drag and drop (`vm.files.drop`), not the clipboard
        guard !content.isEmpty, content.fingerprint != lastApplied else { return }
        lastApplied = content.fingerprint
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
        do {
            var content = try await AgentClipboard.get(connection, types: [.text, .png, .files])
            guard !content.isEmpty, content.fingerprint != lastApplied else { return }
            lastApplied = content.fingerprint
            if !content.files.isEmpty { content.files = try await pullFiles(content.files, on: connection) }
            seenChangeCount = await pasteboard.write(content)
        } catch {
            Self.log.notice("the guest's clipboard could not be fetched: \(String(describing: error), privacy: .public)")
        }
    }

    /// Copies the guest's files into the VM's downloads folder; returns their host paths.
    private func pullFiles(_ paths: [String], on connection: AgentConnection) async throws -> [String] {
        let sink = HostFileSink(root: downloads)
        var pulled: [String] = []
        for path in paths {
            let name = path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? path
            let (handle, url) = try sink.create(name)
            do {
                try await pull(connection, path, handle, sink)
                try handle.close()
                pulled.append(url.path)
            } catch {
                try? handle.close()
                try? FileManager.default.removeItem(at: url)
                throw error
            }
        }
        return pulled
    }
}
