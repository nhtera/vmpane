import Darwin
import Foundation
import Testing
import VMPaneCore

@testable import VMPaneControl
@testable import VMPaneHost

/// A classifier that sees every peer as an unknown process (an agent's).
private let strangers = PeerClassifier(
    selfPID: -1, selfTeamID: nil, selfIsAdHoc: true, identify: { _ in nil }, satisfies: { _, _ in false })

private func entries(_ helper: Harness) throws -> [AuditEntry] {
    let url = helper.bundle.url.appendingPathComponent("logs/mcp-audit.jsonl")
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
    return try text.split(separator: "\n").map { try JSONDecoder().decode(AuditEntry.self, from: Data($0.utf8)) }
}

@Test func agentsAreHeldToTheVMsPolicy() async throws {
    let helper = try await Harness.make()
    await helper.controller.setClassifier(strangers)
    // Policy off: nothing, and the refusal is recorded.
    await #expect(throws: RPCError.self) { try await helper.client.call("vm.info") }
    let log = try entries(helper)
    #expect(log.last?.method == "vm.info" && log.last?.result == "denied" && log.last?.identity == "automated")
    await helper.tearDown()
}

@Test func aTaggedPolicyOpensItsLevelOnly() async throws {
    let helper = try await Harness.make()
    // Set as the app sets it (this connection is still the app's): tagged.
    _ = try await helper.client.call("vm.settings.apply", params: ["patch": ["mcp": ["policy": "observe"]]])
    await helper.controller.setClassifier(strangers)
    #expect(try await helper.client.call("vm.info")["state"] == "stopped")
    do {
        _ = try await helper.client.call("vm.start")
        Issue.record("vm.start needs control")
    } catch let error as RPCError {
        #expect(error.code == ControlErrorCode.policyDenied.rawValue)
    }
    let log = try entries(helper)
    #expect(log.map { $0.result } == ["ok", "denied"])
    #expect(log.map { $0.method } == ["vm.info", "vm.start"])
    #expect(log.allSatisfy { $0.policy == "observe" })
    await helper.tearDown()
}

@Test func aPolicyEditedByHandCountsAsOff() async throws {
    let helper = try await Harness.make(configure: { config in
        config.mcp.policy = .admin  // no tag
    })
    let info = try await helper.client.call("vm.info")  // as the app: it is told why the level does not count
    #expect(info["policy"] == "off" && info["policyTampered"] == true)
    await helper.controller.setClassifier(strangers)
    await #expect(throws: RPCError.self) { try await helper.client.call("vm.info") }
    #expect(try entries(helper).last?.policy == "off")
    await helper.tearDown()
}

@Test func theKillSwitchStopsAgentsButNotTheApp() async throws {
    let helper = try await Harness.make()
    _ = try await helper.client.call("vm.settings.apply", params: ["patch": ["mcp": ["policy": "admin"]]])
    await helper.controller.setClassifier(strangers)
    #expect(try await helper.client.call("vm.info")["state"] == "stopped", "an agent at admin")
    // Anyone may stop agents, the agent itself included.
    _ = try await helper.client.call("mcp.disableAll")
    #expect(KillSwitch.isEngaged(paths: helper.paths))
    // Its connection was closed; a new one is refused.
    let agent = try UDSClient.connect(to: await helper.controller.prepared.runFiles.socketURL)
    defer { agent.close() }
    await #expect(throws: RPCError.self) { try await agent.call("vm.info") }
    await #expect(throws: RPCError.self) { try await agent.call("mcp.enableAll") }  // only the app releases it
    #expect(try entries(helper).last?.reason?.contains("kill switch") == true)
    await helper.tearDown()
}

@Test func anEngagedSwitchWrittenElsewhereIsNoticed() async throws {
    let helper = try await Harness.make()
    _ = try await helper.client.call("vm.settings.apply", params: ["patch": ["mcp": ["policy": "admin"]]])
    await helper.controller.setClassifier(strangers)
    try KillSwitch.engage(paths: helper.paths)  // vmpane mcp kill, with no app running
    try await Task.sleep(for: .milliseconds(1200))
    #expect(await helper.controller.killSwitchEngaged)
    await #expect(throws: RPCError.self) { try await helper.client.call("vm.info") }
    try KillSwitch.release(paths: helper.paths)
    try await Task.sleep(for: .milliseconds(1200))
    #expect(await !helper.controller.killSwitchEngaged)
    await helper.tearDown()
}

private func hello(_ client: UDSClient, session: String) async throws {
    _ = try await client.call(
        "helper.hello",
        params: [
            "proto": 1, "minProto": 1, "client": ["name": "claude-code", "version": "1", "kind": "mcp"], "sessionId": .string(session),
        ])
}

private func agentSnapshots(_ helper: Harness) async throws -> [JSONValue] {
    guard case .array(let all) = try await helper.client.call("vm.snapshot.list") else { return [] }
    return all.filter { $0["origin"] == "agentSession" }
}

/// Before an agent session's first change, the VM is snapshotted, once per session.
@Test func agentSessionsGetAnUndoSnapshot() async throws {
    let helper = try await Harness.make()
    _ = try await helper.client.call("vm.settings.apply", params: ["patch": ["mcp": ["policy": "admin"]]])
    let socket = await helper.controller.prepared.runFiles.socketURL
    await helper.controller.setClassifier(strangers)
    let agent = try UDSClient.connect(to: socket)
    defer { agent.close() }
    try await hello(agent, session: "s1")
    _ = try await agent.call("vm.info")
    #expect(try await agentSnapshots(helper).isEmpty, "reading changes nothing")
    _ = try await agent.call("vm.start")
    let first = try await agentSnapshots(helper)
    #expect(first.count == 1 && first[0]["name"]?.stringValue?.hasPrefix("agent: claude-code") == true)
    _ = try await agent.call("vm.pause")
    #expect(try await agentSnapshots(helper).count == 1, "one per session")
    let other = try UDSClient.connect(to: socket)
    defer { other.close() }
    try await hello(other, session: "s2")
    _ = try await other.call("vm.resume")
    #expect(try await agentSnapshots(helper).count == 2)
    await helper.tearDown()
}

@Test func autoSnapshotCanBeTurnedOff() async throws {
    let helper = try await Harness.make()
    _ = try await helper.client.call("vm.settings.apply", params: ["patch": ["mcp": ["policy": "admin", "autoSnapshot": false]]])
    let socket = await helper.controller.prepared.runFiles.socketURL
    await helper.controller.setClassifier(strangers)
    let agent = try UDSClient.connect(to: socket)
    defer { agent.close() }
    try await hello(agent, session: "s1")
    _ = try await agent.call("vm.start")
    #expect(try await agentSnapshots(helper).isEmpty)
    await helper.tearDown()
}
