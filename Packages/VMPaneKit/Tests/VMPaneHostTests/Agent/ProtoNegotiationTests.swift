import Darwin
import Foundation
import Testing
import VMPaneControl
import VMPaneCore

@testable import VMPaneHost

/// The guest side of a socket pair, scripted by the test: writes frames, reads the host's frames.
final class FakeAgent: @unchecked Sendable {
    let fd: Int32
    private var decoder = AgentFrameDecoder()

    /// Returns the fake and the host's end of the pair.
    static func pair() throws -> (FakeAgent, Int32) {
        var fds: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else { throw POSIXError(.EIO) }
        return (FakeAgent(fd: fds[0]), fds[1])
    }

    init(fd: Int32) {
        self.fd = fd
        var enabled: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
    }

    deinit { Darwin.close(fd) }

    func send(raw: Data) {
        raw.withUnsafeBytes { _ = Darwin.write(fd, $0.baseAddress, $0.count) }
    }

    func send(_ frame: AgentFrame) throws { send(raw: try frame.encoded()) }

    func send(_ message: RPCMessage) throws { try send(.message(AgentCodec.encode(message))) }

    func hello(proto: UInt32 = 1, minProto: UInt32 = 1, token: String? = nil, id: RPCID = .int(1)) throws {
        let params = AgentHelloParams(
            proto: proto, minProto: minProto, agentVersion: "test", os: "linux", arch: "aarch64",
            caps: ["exec", "file"], token: token)
        try send(.request(RPCRequest(id: id, method: AgentMethod.hello, params: RPCParams.encode(params).get())))
    }

    /// The next frame from the host, or nil at EOF / after `seconds`.
    func next(within seconds: Double = 5) async -> AgentFrame? {
        await offPool { self.nextBlocking(within: seconds) }
    }

    func nextMessage(within seconds: Double = 5) async -> RPCMessage? {
        while let frame = await next(within: seconds) {
            if case .message(let data) = frame { return try? AgentCodec.decode(data).get() }
        }
        return nil
    }

    /// True when the host closed its end (EOF within `seconds`).
    func sawClose(within seconds: Double = 5) async -> Bool {
        await offPool { self.sawCloseBlocking(within: seconds) }
    }

    /// Runs a blocking wait on a GCD thread: `poll` on a cooperative-pool thread can starve the host actors the
    /// test is waiting on when many such tests run at once (the full suite), and the wait times out.
    private func offPool<T: Sendable>(_ wait: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(returning: wait()) }
        }
    }

    private func nextBlocking(within seconds: Double) -> AgentFrame? {
        let deadline = Date().addingTimeInterval(seconds)
        while true {
            if let frame = try? decoder.next() { return frame }
            var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let left = Int32(max(0, deadline.timeIntervalSinceNow) * 1000)
            guard poll(&poller, 1, left) > 0 else { return nil }
            var buffer = [UInt8](repeating: 0, count: 65536)
            let count = Darwin.read(fd, &buffer, buffer.count)
            guard count > 0 else { return nil }
            decoder.append(Data(buffer[0..<count]))
        }
    }

    private func sawCloseBlocking(within seconds: Double) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&poller, 1, 100) > 0 else { continue }
            var byte: UInt8 = 0
            if Darwin.read(fd, &byte, 1) <= 0 { return true }
        }
        return false
    }
}

private struct Connected {
    var connection: AgentConnection
    var agent: FakeAgent
    var peer: AgentConnection.Peer
    var pair: (AgentConnection, FakeAgent) { (connection, agent) }
}

private func connected(token: String? = nil, range: ClosedRange<UInt32> = 1...1) async throws -> Connected {
    let (agent, hostFD) = try FakeAgent.pair()
    let connection = AgentConnection(socket: AgentSocket(fd: hostFD), hostVersion: "host-test", token: token, hostRange: range)
    let peer = Task { try await connection.open(helloTimeout: .seconds(5)) }
    try agent.hello(token: token)
    let accepted = try await peer.value
    _ = await agent.nextMessage()  // the hello response
    return Connected(connection: connection, agent: agent, peer: accepted)
}

@Test func helloPicksTheHighestCommonVersion() async throws {
    let (agent, hostFD) = try FakeAgent.pair()
    let connection = AgentConnection(socket: AgentSocket(fd: hostFD), hostVersion: "h", hostRange: 1...3)
    async let peer = connection.open(helloTimeout: .seconds(5))
    try agent.hello(proto: 5, minProto: 2)
    #expect(try await peer.proto == 3)
    guard case .response(let response)? = await agent.nextMessage() else { Issue.record("no hello response"); return }
    #expect(response.outcome == .success(["proto": 3, "hostVersion": "h"]))
}

@Test func agentWithoutACommonVersionGetsProtoUnsupported() async throws {
    let (agent, hostFD) = try FakeAgent.pair()
    let connection = AgentConnection(socket: AgentSocket(fd: hostFD), hostVersion: "h", hostRange: 1...1)
    let peer = Task { try await connection.open(helloTimeout: .seconds(5)) }
    try agent.hello(proto: 3, minProto: 2)
    await #expect(throws: AgentConnection.ConnectionError.self) { try await peer.value }
    guard case .response(let response)? = await agent.nextMessage(), case .failure(let error) = response.outcome else {
        Issue.record("no error response")
        return
    }
    #expect(error.code == AgentErrorCode.protoUnsupported.rawValue)
    #expect(error.data == ["proto": 1, "minProto": 1])
    #expect(await agent.sawClose())
}

@Test func tokenIsCheckedWhenRequired() async throws {
    let (agent, hostFD) = try FakeAgent.pair()
    let connection = AgentConnection(socket: AgentSocket(fd: hostFD), hostVersion: "h", token: "secret")
    let peer = Task { try await connection.open(helloTimeout: .seconds(5)) }
    try agent.hello(token: "wrong")
    await #expect(throws: AgentConnection.ConnectionError.self) { try await peer.value }
    guard case .response(let response)? = await agent.nextMessage(), case .failure(let error) = response.outcome else {
        Issue.record("no error response")
        return
    }
    #expect(error.code == AgentErrorCode.unauthorized.rawValue)
    #expect(await agent.sawClose())
    let accepted = try await connected(token: "secret")
    #expect(accepted.peer.hello.agentVersion == "test")
}

@Test func anythingBeforeHelloOrNoHelloClosesTheConnection() async throws {
    let (agent, hostFD) = try FakeAgent.pair()
    let connection = AgentConnection(socket: AgentSocket(fd: hostFD), hostVersion: "h")
    let peer = Task { try await connection.open(helloTimeout: .seconds(5)) }
    try agent.send(.request(RPCRequest(id: .int(1), method: "agent.info")))
    await #expect(throws: AgentConnection.ConnectionError.violation("expected hello first")) { try await peer.value }

    let (silent, silentFD) = try FakeAgent.pair()
    let waiting = AgentConnection(socket: AgentSocket(fd: silentFD), hostVersion: "h")
    await #expect(throws: AgentConnection.ConnectionError.violation("no hello in time")) {
        try await waiting.open(helloTimeout: .milliseconds(200))
    }
    #expect(await silent.sawClose())
}

/// Each guest misbehaviour after hello drops the connection.
@Test(arguments: [
    "guest request", "unknown notification", "stray response", "data on unknown stream", "oversized frame",
    "clipboard flood", "bad JSON",
])
func violationsAfterHelloCloseTheConnection(_ violation: String) async throws {
    let (connection, agent) = try await connected().pair
    switch violation {
    case "guest request": try agent.send(.request(RPCRequest(id: .int(9), method: "exec.start")))
    case "unknown notification": try agent.send(.request(RPCRequest(id: nil, method: "vm.stop")))
    case "stray response": try agent.send(.response(RPCResponse(id: .int(77), result: [:])))
    case "data on unknown stream": try agent.send(.chunk(stream: 4, data: Data("x".utf8)))
    case "oversized frame":
        var header = Data([0, 0x10, 0, 2])  // length 1 MiB + 2
        header.append(0)
        agent.send(raw: header)
    case "clipboard flood":
        for seq in 0..<12 {
            try agent.send(
                .request(RPCRequest(id: nil, method: AgentMethod.clipboardChanged, params: ["types": ["text"], "seq": .int(Int64(seq))])))
        }
    default: try agent.send(.message(Data("{\"jsonrpc\":".utf8)))
    }
    #expect(await agent.sawClose(), "\(violation)")
    #expect(await !connection.isOpen)
}

@Test func callsCorrelateAndStreamsDeliverData() async throws {
    let (connection, agent) = try await connected().pair
    let names = AgentConnection.StreamNames(inbound: { result in
        [result["stdout"]?.intValue, result["stderr"]?.intValue].compactMap { $0.map(UInt32.init) }
    })
    async let started = connection.call(AgentMethod.execStart, ["argv": ["true"]], streams: names)
    guard case .request(let request)? = await agent.nextMessage(), let id = request.id else {
        Issue.record("no request")
        return
    }
    #expect(request.method == AgentMethod.execStart)
    try agent.send(.response(RPCResponse(id: id, result: ["execId": 1, "stdout": 2, "stderr": 4])))
    // Data right behind the response: the streams must already be registered.
    try agent.send(.chunk(stream: 2, data: Data("hello ".utf8)))
    try agent.send(.chunk(stream: 2, data: Data("world".utf8)))
    try agent.send(.end(stream: 2, status: .ok))
    try agent.send(.end(stream: 4, status: .error))
    try agent.send(.request(RPCRequest(id: nil, method: AgentMethod.execExited, params: ["execId": 1, "code": 0])))
    let result = try await started
    let stdout = try #require(result.inbound[2])
    #expect(try await stdout.collect(limit: 100) == Data("hello world".utf8))
    let stderr = try #require(result.inbound[4])
    await #expect(throws: AgentInbound.Failure.ended(.error)) { try await stderr.collect(limit: 100) }
    var notices = connection.notifications.makeAsyncIterator()
    #expect(await notices.next()?.method == AgentMethod.execExited)
    #expect(await connection.isOpen)
}

@Test func timedOutCallsIgnoreTheirLateAnswer() async throws {
    let (connection, agent) = try await connected().pair
    await #expect(throws: AgentConnection.ConnectionError.timeout) {
        try await connection.call(AgentMethod.agentPing, timeout: .milliseconds(100))
    }
    guard case .request(let late)? = await agent.nextMessage(), let id = late.id else {
        Issue.record("no request")
        return
    }
    try agent.send(.response(RPCResponse(id: id, result: [:])))
    let next = Task { try await connection.call(AgentMethod.agentPing) }
    guard case .request(let ping)? = await agent.nextMessage(), let pingID = ping.id else {
        Issue.record("no second request")
        return
    }
    try agent.send(.response(RPCResponse(id: pingID, error: RPCError(code: AgentErrorCode.busy.rawValue, message: "busy"))))
    await #expect(throws: AgentConnection.ConnectionError.rpc(RPCError(code: AgentErrorCode.busy.rawValue, message: "busy"))) {
        try await next.value
    }
    #expect(await connection.isOpen)
}

@Test func outboundStreamsAreOddAndWithinTheChunkLimit() async throws {
    let (connection, agent) = try await connected().pair
    let stream = try await connection.openOutbound()
    #expect(stream % 2 == 1)
    let payload = Data(count: AgentLimits.maxChunk + 10)
    // The socket buffer is far smaller than a chunk: the fake agent reads while the host writes.
    let sending = Task {
        try await connection.send(payload, on: stream)
        try await connection.end(stream)
    }
    defer { sending.cancel() }
    var sizes: [Int] = []
    while let frame = await agent.next(within: 2) {
        switch frame {
        case .chunk(let id, let data):
            #expect(id == stream)
            sizes.append(data.count)
        case .end(let id, let status):
            #expect(id == stream && status == .ok)
            #expect(sizes == [AgentLimits.maxChunk, 10])
            try await sending.value
            return
        default: break
        }
    }
    Issue.record("no end frame")
}

/// A guest cannot hold more than two connections open without saying hello; the third is closed at once and
/// starts the violation backoff.
@Test func connectionsBeforeHelloAreCapped() async throws {
    let hub = AgentHub(hostVersion: "h")
    let (first, firstFD) = try FakeAgent.pair()
    let (second, secondFD) = try FakeAgent.pair()
    let (third, thirdFD) = try FakeAgent.pair()
    let waiting = [firstFD, secondFD].map { fd in Task { await hub.serve(fd: fd, helloTimeout: .seconds(2)) } }
    try await Task.sleep(for: .milliseconds(100))
    await hub.serve(fd: thirdFD, helloTimeout: .seconds(2))
    #expect(await third.sawClose(within: 1))
    let firstClosed = await first.sawClose(within: 0.2)
    let secondClosed = await second.sawClose(within: 0.2)
    #expect(!firstClosed && !secondClosed)
    for task in waiting { await task.value }  // both time out without hello
    #expect(await hub.status.connected == false)
}
