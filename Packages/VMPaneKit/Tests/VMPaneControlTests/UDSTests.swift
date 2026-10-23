import Darwin
import Foundation
import Testing
import VMPaneCore

@testable import VMPaneControl

/// A short temp directory (socket paths must stay under 104 bytes).
private func withSocketDirectory<T>(_ body: (URL) async throws -> T) async throws -> T {
    let dir = URL(fileURLWithPath: "/tmp/vp-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    return try await body(dir)
}

private let echoHandler: UDSServer.Handler = { request, connection in
    switch request.method {
    case "echo": return .success(request.params ?? .null)
    case "peer": return .success(["uid": .int(Int64(connection.peer.uid)), "pid": .int(Int64(connection.peer.pid))])
    case "slow":
        try? await Task.sleep(for: .milliseconds(200))
        return .success("slow")
    case "subscribe":
        connection.subscribe(["vm"])
        return .success(true)
    case "fail": return .failure(RPCError(.invalidState, "not now"))
    case "big": return .success(.string(String(repeating: "x", count: 1 << 20)))
    default: return .failure(RPCError(.methodNotFound, "unknown method \(request.method)"))
    }
}

private func permissions(_ path: String) -> mode_t {
    var info = stat()
    stat(path, &info)
    return info.st_mode & 0o777
}

@Test func callsErrorsAndPermissions() async throws {
    try await withSocketDirectory { dir in
        let socket = dir.appendingPathComponent("run/abcd1234.sock")
        let server = UDSServer(socketURL: socket, handler: echoHandler)
        try server.start()
        defer { server.stop() }
        #expect(permissions(socket.path) == 0o600)
        #expect(permissions(socket.deletingLastPathComponent().path) == 0o700)

        let client = try UDSClient.connect(to: socket)
        defer { client.close() }
        #expect(try await client.call("echo", params: ["x": 1]) == ["x": 1])
        await #expect(throws: RPCError(.invalidState, "not now")) { try await client.call("fail") }
        await #expect(throws: RPCError(.methodNotFound, "unknown method nope")) { try await client.call("nope") }
        let peer = try await client.call("peer")
        #expect(peer["uid"] == .int(Int64(getuid())))
        #expect(peer["pid"] == .int(Int64(getpid())))
    }
}

@Test func concurrentCallsMatchTheirResponses() async throws {
    try await withSocketDirectory { dir in
        let socket = dir.appendingPathComponent("s.sock")
        let server = UDSServer(socketURL: socket, handler: echoHandler)
        try server.start()
        defer { server.stop() }
        let client = try UDSClient.connect(to: socket)
        defer { client.close() }
        async let slow = client.call("slow")
        let results = try await withThrowingTaskGroup(of: JSONValue.self) { group in
            for i in 0..<50 { group.addTask { try await client.call("echo", params: ["n": .int(Int64(i))]) } }
            return try await group.reduce(into: Set<JSONValue>()) { $0.insert($1) }
        }
        #expect(results == Set((0..<50).map { JSONValue.object(["n": .int(Int64($0))]) }))
        #expect(try await slow == "slow")
    }
}

/// Raw socket for protocol-level tests.
private func rawConnect(_ path: String) throws -> Int32 {
    let fd = try UnixSocket.make()
    try UnixSocket.connect(fd, to: .absolute(path))
    return fd
}

private func readLine(_ fd: Int32) -> String {
    var data = Data()
    var byte: UInt8 = 0
    while read(fd, &byte, 1) == 1 {
        if byte == 0x0A { break }
        data.append(byte)
    }
    return String(bytes: data, encoding: .utf8) ?? ""
}

@Test func malformedLinesGetErrorResponses() async throws {
    try await withSocketDirectory { dir in
        let socket = dir.appendingPathComponent("s.sock")
        let server = UDSServer(socketURL: socket, handler: echoHandler)
        try server.start()
        defer { server.stop() }
        let fd = try rawConnect(socket.path)
        defer { close(fd) }
        try UnixSocket.writeAll(fd, Data("{not json\n".utf8))
        #expect(readLine(fd).contains(#""code":-32700"#))
        try UnixSocket.writeAll(fd, Data(#"[{"jsonrpc":"2.0","id":1,"method":"echo"}]"#.utf8 + [0x0A]))
        #expect(readLine(fd).contains(#""code":-32600"#))
        try UnixSocket.writeAll(fd, Data(#"{"jsonrpc":"2.0","id":9,"method":"echo","params":[1]}"#.utf8 + [0x0A]))
        #expect(readLine(fd) == #"{"id":9,"jsonrpc":"2.0","result":[1]}"#)
    }
}

@Test func oversizedLineClosesTheConnection() async throws {
    try await withSocketDirectory { dir in
        let socket = dir.appendingPathComponent("s.sock")
        let server = UDSServer(socketURL: socket, handler: echoHandler)
        try server.start()
        defer { server.stop() }
        let fd = try rawConnect(socket.path)
        defer { close(fd) }
        try? UnixSocket.writeAll(fd, Data(repeating: 0x20, count: RPCCodec.maxLineBytes + 10))
        #expect(readLine(fd).contains(#""code":-32600"#))
        var byte: UInt8 = 0
        #expect(read(fd, &byte, 1) == 0)  // closed by the server
    }
}

@Test func subscribedClientsGetNotifications() async throws {
    try await withSocketDirectory { dir in
        let socket = dir.appendingPathComponent("s.sock")
        let server = UDSServer(socketURL: socket, handler: echoHandler)
        try server.start()
        defer { server.stop() }
        let client = try UDSClient.connect(to: socket)
        defer { client.close() }
        _ = try await client.call("subscribe")
        server.broadcast(topic: "other", method: "ignored", params: nil)
        server.broadcast(topic: "vm", method: "vm.stateChanged", params: ["state": "running"])
        var iterator = client.notifications.makeAsyncIterator()
        let first = await iterator.next()
        #expect(first == RPCRequest(id: nil, method: "vm.stateChanged", params: ["state": "running"]))
    }
}

@Test func overlongSocketPathUsesRelativeBind() async throws {
    try await withSocketDirectory { dir in
        let deep = dir.appendingPathComponent(String(repeating: "d", count: 60), isDirectory: true)
            .appendingPathComponent(String(repeating: "e", count: 40), isDirectory: true)
        let socket = deep.appendingPathComponent("abcd1234.sock")
        #expect(socket.path.utf8.count > UnixSocketAddress.maxAbsoluteLength)
        let cwd = FileManager.default.currentDirectoryPath
        let server = UDSServer(socketURL: socket, handler: echoHandler)
        try server.start()
        defer { server.stop() }
        let client = try UDSClient.connect(to: socket)
        defer { client.close() }
        #expect(try await client.call("echo", params: ["at": "deep"]) == ["at": "deep"])
        #expect(FileManager.default.currentDirectoryPath == cwd)
    }
}

@Test func closedServerFailsPendingAndTimeoutsFire() async throws {
    try await withSocketDirectory { dir in
        let socket = dir.appendingPathComponent("s.sock")
        let server = UDSServer(socketURL: socket, handler: echoHandler)
        try server.start()
        let client = try UDSClient.connect(to: socket)
        await #expect(throws: ControlClientError.timedOut(method: "slow")) {
            try await client.call("slow", timeout: .milliseconds(20))
        }
        server.stop()
        await #expect(throws: ControlClientError.connectionClosed) { try await client.call("slow") }
        #expect(!FileManager.default.fileExists(atPath: socket.path))
    }
}

@Test func peerIdentityOfOurOwnProcess() async throws {
    try await withSocketDirectory { dir in
        let socket = dir.appendingPathComponent("s.sock")
        let tokens = TokenBox()
        let server = UDSServer(socketURL: socket) { _, connection in
            tokens.set(connection.peer.auditToken)
            return .success(true)
        }
        try server.start()
        defer { server.stop() }
        let client = try UDSClient.connect(to: socket)
        defer { client.close() }
        _ = try await client.call("anything")
        let token = try #require(tokens.value)
        let identity = try #require(PeerIdentity.identity(auditToken: token))
        #expect(identity.identifier?.isEmpty == false)
        if let identifier = identity.identifier {
            #expect(PeerIdentity.satisfies(auditToken: token, requirement: "identifier \"\(identifier)\""))
        }
        #expect(
            !PeerIdentity.satisfies(
                auditToken: token, requirement: PeerIdentity.requirement(identifier: "app.vmpane.mac", teamID: "QCLXRD7V9M")))
    }
}

private final class TokenBox: @unchecked Sendable {
    private let lock = NSLock()
    private var token: Data?
    func set(_ data: Data) { lock.withLock { token = data } }
    var value: Data? { lock.withLock { token } }
}

@Test func halfClosedClientStillGetsItsResponse() async throws {
    // `echo '{…}' | nc -U sock` sends one line and shuts down its writing side at once.
    try await withSocketDirectory { dir in
        let socket = dir.appendingPathComponent("s.sock")
        let server = UDSServer(socketURL: socket, handler: echoHandler)
        try server.start()
        defer { server.stop() }
        for method in ["echo", "slow"] {
            let fd = try rawConnect(socket.path)
            defer { close(fd) }
            try UnixSocket.writeAll(fd, Data(#"{"jsonrpc":"2.0","id":1,"method":"\#(method)","params":{"k":1}}"#.utf8 + [0x0A]))
            shutdown(fd, SHUT_WR)
            #expect(readLine(fd).contains(#""id":1"#), "\(method): no response after half-close")
            var byte: UInt8 = 0
            #expect(read(fd, &byte, 1) == 0)  // then the server closes
        }
    }
}

@Test func largeResponsesArriveWhole() async throws {
    try await withSocketDirectory { dir in
        let socket = dir.appendingPathComponent("s.sock")
        let server = UDSServer(socketURL: socket, handler: echoHandler)
        try server.start()
        defer { server.stop() }
        let client = try UDSClient.connect(to: socket)
        defer { client.close() }
        for _ in 0..<3 {
            let result = try await client.call("big")
            #expect(result.stringValue?.count == 1 << 20)
        }
    }
}

@Test func nullIDRequestsAreRefusedNotRunSilently() async throws {
    try await withSocketDirectory { dir in
        let socket = dir.appendingPathComponent("s.sock")
        let server = UDSServer(socketURL: socket, handler: echoHandler)
        try server.start()
        defer { server.stop() }
        let fd = try rawConnect(socket.path)
        defer { close(fd) }
        try UnixSocket.writeAll(fd, Data(#"{"jsonrpc":"2.0","id":null,"method":"echo"}"#.utf8 + [0x0A]))
        let line = readLine(fd)
        #expect(line.contains(#""code":-32600"#) && line.contains(#""id":null"#))
    }
}

@Test func cancelledCallsReturnAtOnce() async throws {
    try await withSocketDirectory { dir in
        let socket = dir.appendingPathComponent("s.sock")
        let server = UDSServer(socketURL: socket, handler: echoHandler)
        try server.start()
        defer { server.stop() }
        let client = try UDSClient.connect(to: socket)
        defer { client.close() }
        let call = Task { try await client.call("slow", timeout: .seconds(30)) }
        try await Task.sleep(for: .milliseconds(20))
        let start = ContinuousClock.now
        call.cancel()
        await #expect(throws: CancellationError.self) { try await call.value }
        // A thrown CancellationError, not the handler's answer (200 ms), and far from the call's 30 s timeout; a loaded
        // Mac took 1.07 s.
        #expect(ContinuousClock.now - start < .seconds(3), "well before the call's 30 s timeout")
        #expect(try await client.call("echo", params: ["still": "works"]) == ["still": "works"])
    }
}
