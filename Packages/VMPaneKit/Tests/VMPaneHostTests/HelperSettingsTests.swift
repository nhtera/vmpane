import Foundation
import Testing
import VMPaneControl
import VMPaneCore

@testable import VMPaneHost

// vm.settings.apply through a helper with a scripted backend (Harness: HelperLifecycleTests.swift).

@Test func settingsApplyWhileStoppedSavesEverythingChangeable() async throws {
    let helper = try await Harness.make()
    let result = try await helper.client.call(
        "vm.settings.apply", params: ["patch": ["cpu": ["count": 3], "name": "Renamed", "id": "nope", "bogus": 1]])
    #expect(result["fields"] == ["cpu.count": "applied", "name": "applied", "id": "rejected", "bogus": "rejected"])
    #expect(result["reasons"]?["id"] == "cannot be changed")
    let saved = try ConfigStore.load(helper.bundle)
    #expect(saved.cpu.count == 3 && saved.name == "Renamed")
    _ = try await helper.client.call("vm.start")
    #expect(helper.backend.lastStartConfig?.cpu.count == 3)  // the next boot uses the saved settings
    await helper.tearDown()
}

@Test func settingsApplyWhileRunningSplitsLiveAndNextBoot() async throws {
    let helper = try await Harness.make()
    helper.backend.livePaths = ["shares"]
    _ = try await helper.client.call("vm.start")
    let share: JSONValue = ["id": "s1", "name": "data", "hostPath": "/tmp", "readOnly": true]
    let result = try await helper.client.call(
        "vm.settings.apply",
        params: ["patch": ["cpu": ["count": 3], "shares": [share], "display": ["widthPx": 1024], "ui": ["closeAction": "stop"]]])
    #expect(
        result["fields"] == [
            "cpu.count": "nextBoot", "shares": "applied", "display.widthPx": "nextBoot", "ui.closeAction": "applied",
        ])
    #expect(helper.backend.recordedCalls.last == "applyLive.display.widthPx,shares")
    #expect(try ConfigStore.load(helper.bundle).cpu.count == 3)
    await helper.tearDown()
}

@Test func settingsApplyRefusesInvalidPatches() async throws {
    let helper = try await Harness.make()
    await #expect(throws: RPCError.self) {
        try await helper.client.call("vm.settings.apply", params: ["patch": ["cpu": ["count": "many"]]])
    }
    await #expect(throws: RPCError.self) { try await helper.client.call("vm.settings.apply", params: ["patch": 3]) }
    #expect(try ConfigStore.load(helper.bundle).cpu.count >= 1)
    await helper.tearDown()
}

@Test func pendingHardwareSettingsAreReportedAndWarnASuspend() async throws {
    let helper = try await Harness.make()
    _ = try await helper.client.call("vm.start")
    #expect(try await helper.client.call("vm.info")["pendingRestart"] == false)
    _ = try await helper.client.call("vm.settings.apply", params: ["patch": ["cpu": ["count": 3]]])
    #expect(try await helper.client.call("vm.info")["pendingRestart"] == true)
    let suspended = try await helper.client.call("vm.suspend")
    #expect(suspended["message"]?.stringValue?.contains("boots fresh") == true)
    await helper.tearDown()
}

@Test func settingsCanEjectTheInstallerButNotChangeIt() async throws {
    let helper = try await Harness.make(configure: installing)
    let changed = try await helper.client.call("vm.settings.apply", params: ["patch": ["install": ["media": "other"]]])
    #expect(changed["fields"] == ["install.media": "rejected"])
    let ejected = try await helper.client.call("vm.settings.apply", params: ["patch": ["install": nil, "removable": []]])
    #expect(ejected["fields"] == ["install": "applied", "removable": "applied"])
    let saved = try ConfigStore.load(helper.bundle)
    #expect(saved.install == nil && saved.removable.isEmpty)
    await helper.tearDown()
}
