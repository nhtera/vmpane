import Foundation
import Testing
import VMPaneControl
import VMPaneCore

@testable import VMPaneHost

extension HelperController {
    func setInstallReplyAfter(_ wait: Duration) { installReplyAfter = wait }
}

private func installingMacOS(replyAfter: Duration) async throws -> Harness {
    let helper = try await Harness.make(os: .macos) {
        $0.install = Extensible(InstallConfig(restoreImage: "/ipsw/UniversalMac.ipsw"))
    }
    await helper.controller.setInstallReplyAfter(replyAfter)
    return helper
}

@Test func aMacOSInstallStartRepliesOnceUnderWayAndRunsWhenDone() async throws {
    let helper = try await installingMacOS(replyAfter: .milliseconds(300))
    helper.backend.startDelay = .seconds(8)  // the install
    // "installing" is only the reply while the start has not finished.
    let reply = try await helper.client.call("vm.start", params: ["headless": true])
    #expect(reply["state"] == "starting")
    #expect(reply["installing"] == true)
    var running = false
    for _ in 0..<300 where !running {
        try await Task.sleep(for: .milliseconds(50))
        running = try await helper.state() == "running"
    }
    #expect(running)
    await helper.tearDown()
}

@Test func aMacOSInstallRefusedForSpaceIsTheReplyAndTheVMStaysStopped() async throws {
    let helper = try await installingMacOS(replyAfter: .seconds(10))
    helper.backend.failOnce("start", with: InsufficientSpace(requiredBytes: 25 << 30, availableBytes: 3 << 30))
    await #expect(throws: RPCError.self) { try await helper.client.call("vm.start", params: ["headless": true]) }
    #expect(try await helper.state() == "stopped")
    await helper.tearDown()
}
