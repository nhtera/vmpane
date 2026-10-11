import Foundation
import Testing
import VMPaneControl
import VMPaneCore

@testable import VMPaneHost

/// The helper's `agent.*` methods, with the real agent connected through the backend's agent sockets.
private func helperWithAgent() async throws -> (Harness, SpawnedAgent) {
    let helper = try await Harness.make()
    _ = try await helper.client.call("events.subscribe", params: ["topics": ["agent"]])
    var notes = helper.client.notifications.makeAsyncIterator()
    let agent = try await SpawnedAgent.spawn()
    helper.backend.connectAgent(agent.fd)
    let changed = await notes.next()
    #expect(changed?.method == "agent.connectionChanged" && changed?.params?["connected"] == true)
    return (helper, agent)
}

/// Reads notifications until `exec.exited` for `execId`; returns the output by stream and the exit params.
private func collectExec(_ client: UDSClient, _ execId: JSONValue?) async -> (output: [String: String], exited: JSONValue?) {
    var output: [String: String] = [:]
    for await note in client.notifications where note.params?["execId"] == execId {
        if note.method == "exec.output", let name = note.params?["stream"]?.stringValue,
            let data = Data(base64Encoded: note.params?["dataB64"]?.stringValue ?? "")
        {
            output[name, default: ""] += String(bytes: data, encoding: .utf8) ?? ""
        } else if note.method == "exec.exited" {
            return (output, note.params)
        }
    }
    return (output, nil)
}

@Test(.enabled(if: agentBuilt, "build the agent: cd agent && cargo build"))
func helperRunsCommandsThroughTheAgent() async throws {
    let (helper, agent) = try await helperWithAgent()
    let status = try await helper.client.call("agent.status")
    #expect(status["connected"] == true)
    #expect(status["os"] == "macos")
    #expect(status["proto"] == 1)

    let started = try await helper.client.call(
        "agent.exec", params: ["shell": "echo out; echo err >&2; exit 2", "as": "admin"])
    let ran = await collectExec(helper.client, started["execId"])
    #expect(ran.output == ["stdout": "out\n", "stderr": "err\n"])
    #expect(ran.exited?["code"] == 2)

    let cat = try await helper.client.call("agent.exec", params: ["argv": ["/bin/cat"], "as": "admin", "stdin": true])
    let other = try UDSClient.connect(to: await helper.controller.prepared.runFiles.socketURL)
    await #expect(throws: RPCError.self) {  // only the connection that started it may feed or signal it
        _ = try await other.call("agent.exec.signal", params: ["execId": cat["execId"] ?? .null, "signal": "kill"])
    }
    other.close()
    _ = try await helper.client.call(
        "agent.exec.input",
        params: ["execId": cat["execId"] ?? .null, "dataB64": .string(Data("piped".utf8).base64EncodedString()), "eof": true])
    let echoed = await collectExec(helper.client, cat["execId"])
    #expect(echoed.output["stdout"] == "piped")
    #expect(echoed.exited?["code"] == 0)

    agent.cleanUp()
    await helper.tearDown()
}

@Test(.enabled(if: agentBuilt, "build the agent: cd agent && cargo build"))
func helperPushesAndPullsFilesThroughTheAgent() async throws {
    let (helper, agent) = try await helperWithAgent()
    let source = helper.root.appendingPathComponent("source.bin")
    let data = Data((0..<(5 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 31) })
    try data.write(to: source)
    let guestPath = agent.directory.appendingPathComponent("in-guest.bin").path
    let pushed = try await helper.client.call(
        "agent.file.push", params: ["hostPath": .string(source.path), "guestPath": .string(guestPath)])
    #expect(pushed["bytes"] == .int(Int64(data.count)))
    #expect(try Data(contentsOf: URL(fileURLWithPath: guestPath)) == data)

    let back = helper.root.appendingPathComponent("back.bin")
    let pulled = try await helper.client.call("agent.file.pull", params: ["guestPath": .string(guestPath), "hostPath": .string(back.path)])
    #expect(pulled["bytes"] == .int(Int64(data.count)))
    #expect(try Data(contentsOf: back) == data)
    await #expect(throws: RPCError.self) {
        _ = try await helper.client.call("agent.file.pull", params: ["guestPath": "/no/such/file", "hostPath": .string(back.path)])
    }
    #expect(try Data(contentsOf: back) == data, "a failed pull leaves the target alone")

    agent.cleanUp()
    await helper.tearDown()
}

@Test func agentStatusWithoutAnAgent() async throws {
    let helper = try await Harness.make()
    #expect(try await helper.client.call("agent.status") == ["connected": false])
    await helper.tearDown()
}
