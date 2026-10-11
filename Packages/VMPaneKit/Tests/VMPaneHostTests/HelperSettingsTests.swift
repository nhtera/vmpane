import Darwin
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

@Test func portForwardListsAreCheckedBeforeTheyAreSaved() async throws {
    let helper = try await Harness.make()
    func rule(_ id: String, _ address: String, _ port: Int) -> JSONValue {
        [
            "id": .string(id), "proto": "tcp", "hostAddress": .string(address), "hostPort": .int(Int64(port)), "guestPort": 22,
            "origin": "user",
        ]
    }
    let bad = try await helper.client.call(
        "vm.settings.apply", params: ["patch": ["portForwards": [rule("ssh", "127.0.0.1", 2222), rule("x", "10.0.0.1,y", 2223)]]])
    #expect(bad["fields"] == ["portForwards": "rejected"])
    #expect(bad["reasons"]?["portForwards"]?.stringValue?.contains("port forward x") == true)
    let clash = try await helper.client.call(
        "vm.settings.apply", params: ["patch": ["portForwards": [rule("a", "127.0.0.1", 2222), rule("b", "0.0.0.0", 2222)]]])
    #expect(clash["fields"] == ["portForwards": "rejected"])
    #expect(try ConfigStore.load(helper.bundle).portForwards.isEmpty)
    let good = try await helper.client.call("vm.settings.apply", params: ["patch": ["portForwards": [rule("ssh", "127.0.0.1", 2222)]]])
    #expect(good["fields"] == ["portForwards": "applied"])
    #expect(try ConfigStore.load(helper.bundle).portForwards.map(\.id) == ["ssh"])
    await helper.tearDown()
}

/// A VZ VM's forwards are the helper's own listeners: up while it runs, changed live, gone when it stops.
@Test func vzForwardsListenWhileTheVMRuns() async throws {
    let helper = try await Harness.make()
    let port = Int64(UInt16.random(in: 40000...60000))
    let rule: JSONValue = [
        "id": "web", "proto": "tcp", "hostAddress": "127.0.0.1", "hostPort": .int(port), "guestPort": 80, "origin": "user",
    ]
    _ = try await helper.client.call("vm.settings.apply", params: ["patch": ["portForwards": [rule]]])
    #expect(firstStatus(try await helper.client.call("vm.ports.list")) == "inactive")
    _ = try await helper.client.call("vm.start")
    #expect(try await helper.waitForState("running"))
    var listed = try await helper.client.call("vm.ports.list")
    for _ in 0..<50 where firstStatus(listed) != "listening" {
        try await Task.sleep(for: .milliseconds(20))
        listed = try await helper.client.call("vm.ports.list")
    }
    #expect(firstStatus(listed) == "listening")
    // A port another program listens on (all interfaces, like a dev server) is refused before it is saved.
    let other = try Sockets.bound("0.0.0.0", UInt16(port + 2), stream: true)
    defer { close(other) }
    let clash: JSONValue = [
        "id": "web2", "proto": "tcp", "hostAddress": "127.0.0.1", "hostPort": .int(port + 2), "guestPort": 81, "origin": "user",
    ]
    let refused = try await helper.client.call("vm.settings.apply", params: ["patch": ["portForwards": [rule, clash]]])
    #expect(refused["fields"] == ["portForwards": "rejected"])
    let moved: JSONValue = [
        "id": "web", "proto": "tcp", "hostAddress": "127.0.0.1", "hostPort": .int(port + 1), "guestPort": 80, "origin": "user",
    ]
    let changed = try await helper.client.call("vm.settings.apply", params: ["patch": ["portForwards": [moved]]])
    #expect(changed["fields"] == ["portForwards": "applied"])
    _ = try await helper.client.call("vm.stop", params: ["mode": "force"])
    #expect(try await helper.waitForState("stopped"))
    #expect(firstStatus(try await helper.client.call("vm.ports.list")) == "inactive")
    await helper.tearDown()
}

private func firstStatus(_ listed: JSONValue) -> JSONValue? {
    guard case .array(let rules)? = listed["rules"] else { return nil }
    return rules.first?["status"]
}

/// A Windows VM's shares are a WebDAV server on 127.0.0.1 under a per-run token while it runs; share changes
/// apply live; stopping ends it.
@Test func windowsSharesAreServedOverWebDAVWhileTheVMRuns() async throws {
    let helper = try await Harness.make(os: .windows)
    let folder = helper.root.appendingPathComponent("Shared")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data("hi".utf8).write(to: folder.appendingPathComponent("a.txt"))
    _ = try await helper.client.call("vm.start")
    #expect(try await helper.waitForState("running"))
    let webdav = try #require(await helper.controller.webdav)
    #expect(webdav.token.count == 32 && webdav.guestURL.hasPrefix("http://10.0.2.2:\(webdav.port)/"))
    let share: JSONValue = ["id": "s1", "name": "Shared", "hostPath": .string(folder.path), "readOnly": false]
    let applied = try await helper.client.call("vm.settings.apply", params: ["patch": ["shares": [share]]])
    #expect(applied["fields"] == ["shares": "applied"])
    let base = "http://127.0.0.1:\(webdav.port)"
    #expect(await httpGet("\(base)/\(webdav.token)/Shared/a.txt") == "hi")
    #expect(await httpGet("\(base)/Shared/a.txt") == nil, "nothing without the token")
    _ = try await helper.client.call("vm.stop", params: ["mode": "force"])
    #expect(try await helper.waitForState("stopped"))
    #expect(await helper.controller.webdav == nil)
    #expect(await httpGet("\(base)/\(webdav.token)/Shared/a.txt") == nil, "the server is gone")
    await helper.tearDown()
}

/// The body of a 200 answer, or nil.
private func httpGet(_ url: String) async -> String? {
    await withCheckedContinuation { done in
        DispatchQueue.global().async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
            process.arguments = ["-sf", "--max-time", "5", url]
            let output = Pipe()
            process.standardOutput = output
            try? process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            done.resume(returning: process.terminationStatus == 0 ? String(bytes: data, encoding: .utf8) : nil)
        }
    }
}
