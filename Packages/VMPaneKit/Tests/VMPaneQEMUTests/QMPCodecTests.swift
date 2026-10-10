import Darwin
import Foundation
import Testing
import VMPaneCore

@testable import VMPaneQEMU

/// A scripted QMP server on a Unix socket: `script` runs on its own thread with the accepted connection.
private final class FakeQEMU: @unchecked Sendable {
    final class Connection {
        let fd: Int32
        private var framer = LineFramer(maxLineBytes: 1 << 22)
        private var lines: [Data] = []

        init(fd: Int32) { self.fd = fd }

        func send(_ value: JSONValue) {
            var data = (try? JSONEncoder().encode(value)) ?? Data()
            data.append(0x0A)
            sendRaw(data)
        }

        func sendRaw(_ data: Data) { try? UnixSocket.writeAll(fd, data) }

        /// The next client message, or nil when the client closed.
        func receive() -> JSONValue? {
            while lines.isEmpty {
                var buffer = [UInt8](repeating: 0, count: 4096)
                let count = read(fd, &buffer, buffer.count)
                guard count > 0 else { return nil }
                for case .line(let line) in framer.append(Data(buffer[0..<count])) { lines.append(line) }
            }
            return try? JSONDecoder().decode(JSONValue.self, from: lines.removeFirst())
        }
    }

    let socket: URL
    private let listener: Int32
    private let done = DispatchSemaphore(value: 0)

    init(bindAfter delay: TimeInterval = 0, _ script: @escaping @Sendable (Connection) -> Void) throws {
        let dir = URL(fileURLWithPath: "/private/tmp/vp-qmp-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        socket = dir.appendingPathComponent("qmp.sock")
        listener = try UnixSocket.make()
        let (listener, socket, done) = (listener, socket, done)
        Thread {
            defer { done.signal() }
            if delay > 0 { Thread.sleep(forTimeInterval: delay) }
            guard (try? UnixSocket.bind(listener, to: .absolute(socket.path))) != nil, listen(listener, 1) == 0 else { return }
            let fd = accept(listener, nil, nil)
            guard fd >= 0 else { return }
            script(Connection(fd: fd))
            close(fd)
        }.start()
    }

    static let greeting: JSONValue = [
        "QMP": ["version": ["qemu": ["major": 11, "minor": 1, "micro": 2], "package": ""], "capabilities": ["oob"]]
    ]

    /// Greeting and `qmp_capabilities`, as QEMU does them.
    static func handshake(_ connection: Connection) {
        connection.send(greeting)
        guard let request = connection.receive() else { return }
        connection.send(["return": [:], "id": request["id"] ?? .null])
    }

    func finish() {
        close(listener)
        done.wait()
        try? FileManager.default.removeItem(at: socket.deletingLastPathComponent())
    }
}

private func transcript(_ name: String, sourceFile: String = #filePath) throws -> [(client: Bool, message: JSONValue)] {
    let url = URL(fileURLWithPath: sourceFile).deletingLastPathComponent().appendingPathComponent("Fixtures/qmp-transcripts/\(name).jsonl")
    return try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map { line in
        let entry = try JSONDecoder().decode(JSONValue.self, from: Data(line.utf8))
        if let message = entry["c"] { return (true, message) }
        return (false, try #require(entry["s"]))
    }
}

/// Replays a transcript captured from the shipped QEMU: the client sends the same commands and must get
/// the same answers and events, in order.
@Test func replaysARealQEMUSession() async throws {
    let entries = try transcript("lifecycle")
    let server = try FakeQEMU { connection in
        var lastID: JSONValue = .null
        for (fromClient, message) in entries {
            if fromClient {
                guard let request = connection.receive(), request["execute"] == message["execute"] else { return }
                lastID = request["id"] ?? .null
            } else if case .object(var object) = message {
                if object["id"] != nil { object["id"] = lastID }
                connection.send(.object(object))
            }
        }
    }
    defer { server.finish() }

    let client = try await QMPClient.connect(to: server.socket)
    #expect(client.version?["qemu"]?["major"] == 11)
    var events = client.events.makeAsyncIterator()
    let status = try await client.execute("query-status")
    #expect(status["status"] == "running")
    try await client.execute("stop")
    #expect(await events.next()?.name == "STOP")
    #expect(try await client.execute("query-status")["status"] == "paused")
    try await client.execute("cont")
    #expect(await events.next()?.name == "RESUME")
    await #expect(
        throws: QMPError.commandFailed(
            command: "no-such-command", errorClass: "CommandNotFound", description: "The command no-such-command has not been found")
    ) {
        try await client.execute("no-such-command")
    }
    #expect(try await client.execute("query-name") == .object([:]))
    try await client.execute("system_powerdown")
    #expect(await events.next()?.name == "POWERDOWN")
    try await client.execute("quit")
    let shutdown = await events.next()
    #expect(shutdown?.name == "SHUTDOWN" && shutdown?.data["reason"] == "host-qmp-quit" && shutdown?.timestamp != nil)
    #expect(await events.next() == nil)  // QEMU closed the connection after quit
    await #expect(throws: QMPError.connectionClosed) { try await client.execute("query-status") }
}

@Test func messagesAreDecodedStrictly() throws {
    func decode(_ text: String) throws -> QMPMessage { try QMPMessage.decode(Data(text.utf8)) }
    #expect(try decode(#"{"return": {"a": 1}, "id": 7}"#) == .success(id: 7, ["a": 1]))
    #expect(
        try decode(#"{"error": {"class": "GenericError", "desc": "x"}}"#) == .failure(id: nil, errorClass: "GenericError", description: "x")
    )
    #expect(try decode(#"{"event": "RESET", "data": {"guest": true}}"#) == .event(QMPEvent(name: "RESET", data: ["guest": true])))
    for bad in [
        "[1]", "\"x\"", "{}", #"{"QMP": 1}"#, #"{"QMP": {}, "x": 1}"#, #"{"event": ""}"#, #"{"event": "X", "data": [1]}"#,
        #"{"error": {"class": "X"}}"#, #"{"return": {}, "id": "seven"}"#, "not json",
    ] {
        #expect(throws: (any Error).self, "accepted \(bad)") { try decode(bad) }
    }
}

@Test func anOversizedLineClosesTheConnection() async throws {
    let server = try FakeQEMU { connection in
        FakeQEMU.handshake(connection)
        _ = connection.receive()
        connection.sendRaw(Data(repeating: 0x20, count: QMPClient.maxLineBytes + 2))
        _ = connection.receive()
    }
    defer { server.finish() }
    let client = try await QMPClient.connect(to: server.socket)
    await #expect(throws: QMPError.protocolViolation("line longer than \(QMPClient.maxLineBytes) bytes")) {
        try await client.execute("query-status")
    }
    var events = client.events.makeAsyncIterator()
    #expect(await events.next() == nil)
}

@Test func unansweredCommandsTimeOutAndClosedConnectionsFailPending() async throws {
    let server = try FakeQEMU { connection in
        FakeQEMU.handshake(connection)
        _ = connection.receive()  // never answered
        _ = connection.receive()  // answered by closing
    }
    defer { server.finish() }
    let client = try await QMPClient.connect(to: server.socket)
    await #expect(throws: QMPError.timedOut(command: "query-status")) {
        try await client.execute("query-status", timeout: .milliseconds(200))
    }
    await #expect(throws: QMPError.connectionClosed) { try await client.execute("query-status") }
}

@Test func connectWaitsForTheSocketAndRejectsABadGreeting() async throws {
    let late = try FakeQEMU(bindAfter: 0.3) { FakeQEMU.handshake($0) }
    defer { late.finish() }
    let client = try await QMPClient.connect(to: late.socket, timeout: .seconds(5))
    client.close()

    let liar = try FakeQEMU { connection in
        connection.send(["return": [:]])
        _ = connection.receive()
    }
    defer { liar.finish() }
    await #expect(throws: QMPError.self) { _ = try await QMPClient.connect(to: liar.socket, timeout: .seconds(2)) }
}

@Test func eventsAreBoundedWhenNobodyReads() async throws {
    let flood = QMPClient.eventBufferLimit + 500
    let server = try FakeQEMU { connection in
        FakeQEMU.handshake(connection)
        for index in 0..<flood { connection.send(["event": "RTC_CHANGE", "data": ["offset": .int(Int64(index))]]) }
        guard let request = connection.receive() else { return }
        connection.send(["return": [:], "id": request["id"] ?? .null])
    }
    defer { server.finish() }
    let client = try await QMPClient.connect(to: server.socket)
    try await client.execute("query-status")  // answered after every event was sent
    client.close()
    var received: [JSONValue] = []
    for await event in client.events { received.append(event.data["offset"] ?? .null) }
    #expect(received.count == QMPClient.eventBufferLimit)
    #expect(received.last == .int(Int64(flood - 1)))  // the newest are kept
}
