import Foundation
import Testing
import VMPaneCore

@testable import VMPaneControl
@testable import VMPaneHost

// When the helper updates a guest's older tools by itself (HelperController+ToolsUpdate).

private func peer(_ version: String, os: String = "linux", caps: [String] = ["exec", "file"]) -> AgentConnection.Peer {
    AgentConnection.Peer(
        hello: AgentHelloParams(proto: 1, minProto: 1, agentVersion: version, os: os, arch: "aarch64", caps: caps), proto: 1)
}

/// A version before this VMPane's (its pre-release, or its patch, one lower).
private var older: String {
    guard let current = ReleaseVersion(VMPane.version) else { return "0.9.0" }
    if let number = current.prerelease.last.flatMap(Int.init), number > 0 {
        return current.description.replacingOccurrences(of: ".\(number)", with: ".\(number - 1)", options: .backwards)
    }
    return "0.9.0"
}

extension HelperController {
    func noteAgentActedNow(_ method: String = "vm.input.key") {
        activity.recent = [.init(client: "test", method: method, ok: true, when: Date())] + activity.recent
    }
    func markToolsUpdateTried() { toolsUpdate.tried = true }
}

@Test func onlyAnOlderLinuxOrWindowsAgentIsDueAnUpdate() async throws {
    let helper = try await Harness.make()
    defer { Task { await helper.tearDown() } }
    let controller = helper.controller
    #expect(await controller.toolsUpdateDue(peer(older)))
    #expect(await controller.toolsUpdateDue(peer(older, os: "windows")))
    #expect(!(await controller.toolsUpdateDue(peer(VMPane.version))))
    #expect(!(await controller.toolsUpdateDue(peer("99.0.0"))))
    #expect(!(await controller.toolsUpdateDue(peer(older, os: "macos"))))  // updated by hand
    #expect(!(await controller.toolsUpdateDue(peer(older, caps: ["exec"]))))  // cannot receive files
    #expect(!(await controller.toolsUpdateDue(peer("test"))))  // no version to compare
    #expect(HelperController.toolsOutdated(older) && !HelperController.toolsOutdated(VMPane.version))
    // Once per helper run and version.
    await controller.markToolsUpdateTried()
    #expect(!(await controller.toolsUpdateDue(peer(older))))
}

@Test func theSwitchInTheVMsSettingsTurnsUpdatesOff() async throws {
    let helper = try await Harness.make()
    defer { Task { await helper.tearDown() } }
    let result = try await helper.client.call("vm.settings.apply", params: ["patch": ["agent": ["autoUpdate": false]]])
    #expect(result["fields"]?["agent.autoUpdate"] == "applied")
    #expect(!(await helper.controller.toolsUpdateDue(peer(older))))
}

@Test func anUpdateWaitsForTheVMToRunAndForAgentsToPause() async throws {
    let helper = try await Harness.make()
    defer { Task { await helper.tearDown() } }
    let controller = helper.controller
    #expect(await controller.toolsUpdateMustWait())  // stopped
    _ = try await helper.client.call("vm.start", params: ["headless": true])
    #expect(try await helper.waitForState("running"))
    #expect(!(await controller.toolsUpdateMustWait()))
    await controller.noteAgentActedNow("agent.status")  // an agent polling the VM's status does not hold it back
    #expect(!(await controller.toolsUpdateMustWait()))
    await controller.noteAgentActedNow()
    await controller.noteAgentActedNow("vm.screenshot")  // nor does its look after typing end the wait
    #expect(await controller.toolsUpdateMustWait())
}
