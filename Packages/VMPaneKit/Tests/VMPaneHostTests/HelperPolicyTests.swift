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
