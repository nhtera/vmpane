import AppKit
import Foundation
import Synchronization
import Testing
import VMPaneControl
import VMPaneCore

@testable import VMPaneHost

/// The Mac's side, scripted: a change count and contents the bridge reads and writes.
private final class FakePasteboard: HostPasteboard, @unchecked Sendable {
    private let state = Mutex<(count: Int, content: ClipboardContent)>((0, ClipboardContent()))

    var content: ClipboardContent { state.withLock { $0.content } }

    func set(_ content: ClipboardContent) { state.withLock { $0 = ($0.count + 1, content) } }

    func changeCount() async -> Int { state.withLock { $0.count } }
    func read() async -> ClipboardContent { state.withLock { $0.content } }
    func write(_ content: ClipboardContent) async -> Int {
        state.withLock {
            $0 = ($0.count + 1, content)
            return $0.count
        }
    }
}

/// The real agent as a macOS guest's would run: the daemon and a user-session helper that owns a private named
/// pasteboard (never the user's).
private struct ClipboardGuest {
    let spawned: SpawnedAgent
    let session: Process
    let connection: AgentConnection
    let board: NSPasteboard

    static func start() async throws -> ClipboardGuest {
        let name = "app.vmpane.test.\(UUID().uuidString.prefix(8))"
        let directory = URL(fileURLWithPath: "/tmp/vpc-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sessionSocket = directory.appendingPathComponent("session.sock").path
        let spawned = try await SpawnedAgent.spawn(["--session-socket", sessionSocket, "--session-uid", String(getuid())])
        let connection = AgentConnection(fd: spawned.fd, hostVersion: "e2e")
        _ = try await connection.open(helloTimeout: .seconds(10))
        let session = Process()
        session.executableURL = agentBinary
        session.arguments = ["session", "--socket", sessionSocket, "--once"]
        session.environment = ProcessInfo.processInfo.environment.merging(["VMPANE_TEST_PASTEBOARD": name]) { $1 }
        session.standardError = FileHandle.nullDevice
        try session.run()
        for _ in 0..<100 {
            let info = try? await connection.call(AgentMethod.agentInfo, timeout: .seconds(2))
            if info?.result["session"] == true { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        return ClipboardGuest(spawned: spawned, session: session, connection: connection, board: NSPasteboard(name: .init(name)))
    }

    func stop() async {
        session.terminate()
        await connection.close(.closed("test done"))
        spawned.cleanUp()
        board.releaseGlobally()
    }
}

private func eventually(_ condition: () async -> Bool) async -> Bool {
    for _ in 0..<60 {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(100))
    }
    return await condition()
}

@Test(.enabled(if: agentBuilt, "build the agent: cd agent && cargo build"))
func clipboardTravelsBothWaysWithoutPingPong() async throws {
    let guest = try await ClipboardGuest.start()
    let downloads = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("vpc-dl-\(UUID().uuidString.prefix(8))")
    defer { try? FileManager.default.removeItem(at: downloads) }
    let mac = FakePasteboard()
    // The guest shares the Mac's disk here: a file "put in the guest" keeps its path.
    let execs = AgentExecs()
    let bridge = ClipboardBridge(
        pasteboard: mac, mode: .both, staging: downloads,
        pull: { connection, paths, sink, prefix in
            let guest = HelperController.Guest(connection: connection, execs: execs, windows: false)
            return try await HelperController.pullTree(paths, into: sink, under: prefix, from: guest)
        },
        push: { _, paths in paths })
    await bridge.attach(guest.connection)
    let notifications = guest.connection.notifications
    let relay = Task {
        for await notice in notifications where notice.method == AgentMethod.clipboardChanged {
            await bridge.guestChanged()
        }
    }
    defer { relay.cancel() }
    await bridge.setFocused(true)

    // Mac → guest: text, through the poll.
    mac.set(ClipboardContent(text: "from the Mac é😀"))
    #expect(await eventually { guest.board.string(forType: .string) == "from the Mac é😀" })

    // Guest → Mac: text the guest copies arrives, and is not sent back as a new change.
    guest.board.clearContents()
    guest.board.setString("from the guest", forType: .string)
    #expect(await eventually { mac.content.text == "from the guest" })
    let count = await mac.changeCount()
    try await Task.sleep(for: .milliseconds(800))
    #expect(await mac.changeCount() == count, "no ping-pong")

    // Unfocused: nothing moves; on focus the guest's latest change is fetched.
    await bridge.setFocused(false)
    guest.board.clearContents()
    guest.board.setString("while away", forType: .string)
    try await Task.sleep(for: .milliseconds(800))
    #expect(mac.content.text != "while away")
    await bridge.setFocused(true)
    #expect(await eventually { mac.content.text == "while away" })

    await bridge.stop()
    await guest.stop()
}

@Test(.enabled(if: agentBuilt, "build the agent: cd agent && cargo build"))
func filesTravelBothWaysThroughStaging() async throws {
    let guest = try await ClipboardGuest.start()
    let downloads = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("vpc-dl-\(UUID().uuidString.prefix(8))")
    defer { try? FileManager.default.removeItem(at: downloads) }
    let mac = FakePasteboard()
    // The guest shares the Mac's disk here: a file "put in the guest" keeps its path.
    let execs = AgentExecs()
    let bridge = ClipboardBridge(
        pasteboard: mac, mode: .both, staging: downloads,
        pull: { connection, paths, sink, prefix in
            let guest = HelperController.Guest(connection: connection, execs: execs, windows: false)
            return try await HelperController.pullTree(paths, into: sink, under: prefix, from: guest)
        },
        push: { _, paths in paths })
    await bridge.attach(guest.connection)
    let notifications = guest.connection.notifications
    let relay = Task {
        for await notice in notifications where notice.method == AgentMethod.clipboardChanged {
            await bridge.guestChanged()
        }
    }
    defer { relay.cancel() }
    await bridge.setFocused(true)

    // Files copied in the guest land in the VM's staging folder, quarantined, and the Mac gets those.
    let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("vpc-\(UUID().uuidString.prefix(6)) report.txt")
    try Data("guest file".utf8).write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    guest.board.clearContents()
    guest.board.writeObjects([file as NSURL])
    #expect(await eventually { mac.content.files.count == 1 })
    let landed = try #require(mac.content.files.first)
    #expect(landed.hasPrefix(downloads.path) && landed.hasSuffix("report.txt"))
    #expect(try String(contentsOfFile: landed, encoding: .utf8) == "guest file")

    // The next copy of files gets a staging folder of its own; the one before goes.
    let second = file.deletingLastPathComponent().appendingPathComponent("vpc-\(UUID().uuidString.prefix(6)) notes.txt")
    try Data("second".utf8).write(to: second)
    defer { try? FileManager.default.removeItem(at: second) }
    guest.board.clearContents()
    guest.board.writeObjects([second as NSURL])
    #expect(await eventually { mac.content.files.first?.hasSuffix("notes.txt") == true })
    #expect(!FileManager.default.fileExists(atPath: landed))
    #expect(try FileManager.default.contentsOfDirectory(atPath: downloads.path).count == 1)

    // Files copied on the Mac reach the guest's clipboard as files, with their names as text, without Finder's icon.
    let icon = try #require(
        NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)?
            .representation(using: .png, properties: [:]))
    mac.set(ClipboardContent(text: file.lastPathComponent, png: icon, files: [file.path]))
    #expect(await eventually { (guest.board.readObjects(forClasses: [NSURL.self]) as? [URL])?.map(\.path) == [file.path] })
    #expect(guest.board.data(forType: .png) == nil)

    await bridge.stop()
    await guest.stop()
}

@Test(.enabled(if: agentBuilt, "build the agent: cd agent && cargo build"))
func formattedTextTravelsWhenKeptAndPlainTextOtherwise() async throws {
    let guest = try await ClipboardGuest.start()
    let downloads = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("vpc-dl-\(UUID().uuidString.prefix(8))")
    defer { try? FileManager.default.removeItem(at: downloads) }
    let mac = FakePasteboard()
    let bridge = ClipboardBridge(pasteboard: mac, mode: .both, staging: downloads, pull: { _, _, _, _ in [] }, push: { _, _ in [] })
    await bridge.attach(guest.connection)
    let notifications = guest.connection.notifications
    let relay = Task {
        for await notice in notifications where notice.method == AgentMethod.clipboardChanged {
            await bridge.guestChanged()
        }
    }
    defer { relay.cancel() }
    await bridge.setRich(true)
    await bridge.setFocused(true)

    // Mac → guest: HTML and RTF go with the plain text.
    let rtf = Data(#"{\rtf1\ansi {\b bold} text}"#.utf8)
    mac.set(ClipboardContent(text: "bold text", html: "<b>bold</b> text", rtf: rtf))
    #expect(await eventually { guest.board.string(forType: .html) == "<b>bold</b> text" })
    #expect(guest.board.string(forType: .string) == "bold text")
    #expect(guest.board.data(forType: .rtf) == rtf)

    // Guest → Mac: the same.
    guest.board.clearContents()
    guest.board.setString("italic", forType: .string)
    guest.board.setString("<i>italic</i>", forType: .html)
    #expect(await eventually { mac.content.html == "<i>italic</i>" })
    #expect(mac.content.text == "italic")

    // "Keep text formatting" off: plain text only, both ways.
    await bridge.setRich(false)
    mac.set(ClipboardContent(text: "plain now", html: "<u>plain now</u>"))
    #expect(await eventually { guest.board.string(forType: .string) == "plain now" })
    #expect(guest.board.string(forType: .html) == nil)
    guest.board.clearContents()
    guest.board.setString("back plain", forType: .string)
    guest.board.setString("<s>back plain</s>", forType: .html)
    #expect(await eventually { mac.content.text == "back plain" })
    #expect(mac.content.html == nil)

    await bridge.stop()
    await guest.stop()
}

@Test(.enabled(if: agentBuilt, "build the agent: cd agent && cargo build"))
func clipboardMethodsReadAndWriteTheGuests() async throws {
    let guest = try await ClipboardGuest.start()
    try await AgentClipboard.set(guest.connection, ClipboardContent(text: "set by a client"))
    #expect(guest.board.string(forType: .string) == "set by a client")
    let read = try await AgentClipboard.get(guest.connection, types: [.text])
    #expect(read.text == "set by a client")
    await guest.stop()
}
