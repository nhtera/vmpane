import CryptoKit
import Foundation
import Testing
import VMPaneControl
import VMPaneCore

@testable import VMPaneHost

private struct RealAgent {
    let connection: AgentConnection
    let spawned: SpawnedAgent
    var directory: URL { spawned.directory }

    static func start() async throws -> RealAgent {
        let spawned = try await SpawnedAgent.spawn()
        let connection = AgentConnection(fd: spawned.fd, hostVersion: "e2e")
        _ = try await connection.open(helloTimeout: .seconds(10))
        return RealAgent(connection: connection, spawned: spawned)
    }

    func stop() async {
        await connection.close(.closed("test done"))
        spawned.cleanUp()
    }
}

private let execStreams = AgentConnection.StreamNames(inbound: { result in
    [result["stdout"]?.intValue, result["stderr"]?.intValue].compactMap { $0.map(UInt32.init) }
})

@Test(.enabled(if: agentBuilt, "build the agent: cd agent && cargo build"))
func realAgentNegotiatesAndRunsCommands() async throws {
    let agent = try await RealAgent.start()
    let peer = try #require(await agent.connection.agent)
    #expect(peer.proto == 1)
    #expect(peer.hello.os == "macos")
    #expect(peer.hello.caps?.contains(AgentCap.exec) == true)

    var notices = agent.connection.notifications.makeAsyncIterator()
    let started = try await agent.connection.call(
        AgentMethod.execStart, ["shell": "echo hello; echo oops >&2; exit 4", "as": "admin"], streams: execStreams)
    let exec = try RPCParams.decode(AgentExecStartResult.self, from: started.result).get()
    let stdout = try await #require(started.inbound[exec.stdout]).collect(limit: 1 << 20)
    let stderr = try await #require(started.inbound[exec.stderr]).collect(limit: 1 << 20)
    #expect(String(bytes: stdout, encoding: .utf8) == "hello\n")
    #expect(String(bytes: stderr, encoding: .utf8) == "oops\n")
    let exited = try #require(await notices.next())
    #expect(exited.method == AgentMethod.execExited)
    #expect(exited.params?["code"] == 4)
    await agent.stop()
}

@Test(.enabled(if: agentBuilt, "build the agent: cd agent && cargo build"))
func realAgentPushesAndPullsFiles() async throws {
    let agent = try await RealAgent.start()
    var generator = SystemRandomNumberGenerator()
    let data = Data((0..<(3 << 20)).map { _ in UInt8.random(in: 0...255, using: &generator) })
    let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    let target = agent.directory.appendingPathComponent("pushed.bin")

    let stream = try await agent.connection.openOutbound()
    let push = try await agent.connection.start(
        AgentMethod.filePush,
        RPCParams.encode(AgentFilePushParams(path: target.path, size: UInt64(data.count), sha256: sha, stream: stream)).get())
    try await agent.connection.send(data, on: stream)
    try await agent.connection.end(stream)
    let pushed = try await agent.connection.response(push, timeout: .seconds(30))
    #expect(pushed.result["sha256"] == .string(sha))
    #expect(try Data(contentsOf: target) == data)

    let pull = try await agent.connection.call(
        AgentMethod.filePull, RPCParams.encode(AgentFilePullParams(path: target.path, maxBytes: 1 << 30)).get(),
        streams: AgentConnection.StreamNames(inbound: { [$0["stream"]?.intValue].compactMap { $0.map(UInt32.init) } }))
    let pulled = try await #require(pull.inbound.values.first).collect(limit: 1 << 30)
    #expect(pulled == data)
    await agent.stop()
}
