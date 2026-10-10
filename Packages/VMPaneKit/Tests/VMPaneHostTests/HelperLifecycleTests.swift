import Foundation
import Testing
import VMPaneControl
import VMPaneCore

@testable import VMPaneHost

/// A helper with a scripted backend on a real socket, in a short temp root.
private struct Harness {
    let root: URL
    let paths: VMPanePaths
    let bundle: VMBundle
    let controller: HelperController
    let backend: ScriptedBackend
    let client: UDSClient

    static func make(memoryMiB: Int = 64, closeAction: UIConfig.CloseAction = .keepRunning) async throws -> Harness {
        let root = URL(fileURLWithPath: "/tmp/vp-l-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let paths = VMPanePaths(root: root.appendingPathComponent("s"))
        var config = VMConfigV1(VMConfigFields.new(name: "L", os: .linux, macAddress: MachineIdentity.randomMACAddress()))
        config.memory.mib = memoryMiB
        config.ui.closeAction = closeAction
        let bundle = try VMBundle.create(at: root.appendingPathComponent("L.vmpane"), config: config)
        let prepared = try LaunchCoordinator.prepareBundle(bundle, paths: paths, runtimeVersion: "t")
        let backend = ScriptedBackend()
        let controller = HelperController(prepared: prepared, runtimeVersion: "t", backend: backend) {}
        try await controller.start()
        let client = try UDSClient.connect(to: prepared.runFiles.socketURL)
        return Harness(root: root, paths: paths, bundle: bundle, controller: controller, backend: backend, client: client)
    }

    func state() async throws -> String? { try await client.call("vm.info")["state"]?.stringValue }

    func waitForState(_ state: String) async throws -> Bool {
        for _ in 0..<100 {
            if try await self.state() == state { return true }
            try await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    func stateFiles() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: bundle.stateDirectory.path)) ?? []).sorted()
    }

    func tearDown() async {
        client.close()
        await controller.shutdown()
        try? FileManager.default.removeItem(at: root)
    }
}

@Test func startPauseResumeStopAnnounceStateChanges() async throws {
    let helper = try await Harness.make()
    _ = try await helper.client.call("events.subscribe", params: ["topics": ["vm"]])
    var notes = helper.client.notifications.makeAsyncIterator()
    #expect(try await helper.client.call("vm.start", params: ["headless": true])["state"] == "running")
    #expect(await notes.next()?.params?["state"] == "starting")
    #expect(await notes.next()?.params?["state"] == "running")
    #expect(try await helper.client.call("vm.pause")["state"] == "paused")
    #expect(try await helper.client.call("vm.resume")["state"] == "running")
    await #expect(throws: RPCError.self) { try await helper.client.call("vm.start") }  // already running
    _ = try await helper.client.call("vm.stop", params: ["mode": "graceful"])
    #expect(try await helper.waitForState("stopped"))
    #expect(helper.backend.recordedCalls == ["start", "pause", "resume", "stop.graceful"])
    await helper.tearDown()
}

@Test func suspendThenStartResumesAndConsumesTheState() async throws {
    let helper = try await Harness.make()
    _ = try await helper.client.call("vm.start")
    #expect(try await helper.client.call("vm.suspend")["state"] == "stopped")
    #expect(helper.stateFiles() == ["suspend.json", "suspend.scripted"])
    _ = try await helper.client.call("vm.start")
    #expect(helper.backend.recordedCalls.last == "start.resume")
    #expect(helper.stateFiles().isEmpty)
    await helper.tearDown()
}

@Test func stateFromAnotherGenerationIsDiscardedNotRetried() async throws {
    let helper = try await Harness.make()
    _ = try await helper.client.call("vm.start")
    _ = try await helper.client.call("vm.suspend")
    try Generation().write(to: helper.bundle.generationURL)  // e.g. a snapshot restore replaced the disks
    _ = try await helper.client.call("vm.start")
    #expect(helper.backend.recordedCalls.last == "start")  // cold boot
    #expect(helper.stateFiles().isEmpty)
    await helper.tearDown()
}

@Test func failedRestoreFallsBackToColdBoot() async throws {
    let helper = try await Harness.make()
    _ = try await helper.client.call("vm.start")
    _ = try await helper.client.call("vm.suspend")
    helper.backend.failOnce("start.resume")
    #expect(try await helper.client.call("vm.start")["state"] == "running")
    #expect(Array(helper.backend.recordedCalls.suffix(2)) == ["start.resume", "start"])
    #expect(helper.stateFiles().isEmpty)
    await helper.tearDown()
}

@Test func failedSuspendLeavesTheVMRunningWithoutState() async throws {
    let helper = try await Harness.make()
    _ = try await helper.client.call("vm.start")
    helper.backend.failOnce("suspend")
    await #expect(throws: RPCError.self) { try await helper.client.call("vm.suspend") }
    #expect(try await helper.state() == "running")
    #expect(helper.stateFiles().isEmpty)
    await helper.tearDown()
}

@Test func suspendIsRefusedWithoutSpaceForTheRAMState() async throws {
    let helper = try await Harness.make(memoryMiB: 64 << 20)  // 64 TiB of "RAM"
    _ = try await helper.client.call("vm.start")
    do {
        _ = try await helper.client.call("vm.suspend")
        Issue.record("expected insufficientSpace")
    } catch let error as RPCError {
        #expect(error.knownCode == .insufficientSpace)
    }
    #expect(try await helper.state() == "running")
    await helper.tearDown()
}

@Test func strayBackendEventsAreIgnored() async throws {
    let helper = try await Harness.make()
    helper.backend.emit(.paused)  // nonsense while stopped
    helper.backend.emit(.suspended)
    try await Task.sleep(for: .milliseconds(50))
    #expect(try await helper.state() == "stopped")
    _ = try await helper.client.call("vm.start")
    helper.backend.emit(.stopped(reason: "guest powered off"))
    #expect(try await helper.waitForState("stopped"))
    await helper.tearDown()
}

@Test func shutdownStopsTheVMBeforeReleasingTheLock() async throws {
    let helper = try await Harness.make()
    _ = try await helper.client.call("vm.start")
    helper.backend.ignoresGracefulStop = false
    await helper.controller.shutdown()
    #expect(helper.backend.recordedCalls.contains("stop.graceful"))
    #expect(try helper.bundle.tryLock(retryingFor: 1) != nil)
    try? FileManager.default.removeItem(at: helper.root)
}

@Test func shutdownSuspendsWhenTheCloseActionSaysSo() async throws {
    let helper = try await Harness.make(closeAction: .suspend)
    _ = try await helper.client.call("vm.start")
    await helper.controller.shutdown()
    #expect(helper.backend.recordedCalls.last == "suspend")
    #expect(helper.stateFiles() == ["suspend.json", "suspend.scripted"])
    try? FileManager.default.removeItem(at: helper.root)
}

@Test func shutdownForcesOffAGuestThatIgnoresTheGracefulStop() async throws {
    let helper = try await Harness.make()
    _ = try await helper.client.call("vm.start")
    helper.backend.ignoresGracefulStop = true
    await helper.controller.setGracefulStopTimeout(.milliseconds(200))
    await helper.controller.shutdown()
    #expect(Array(helper.backend.recordedCalls.suffix(2)) == ["stop.graceful", "stop.force"])
    #expect(try helper.bundle.tryLock(retryingFor: 1) != nil)
    try? FileManager.default.removeItem(at: helper.root)
}

@Test func liveSnapshotPausesSavesAndResumes() async throws {
    let helper = try await Harness.make()
    _ = try await helper.client.call("vm.start")
    let meta = try await helper.client.call("vm.snapshot.create", params: ["name": "live", "kind": "live"])
    #expect(meta["kind"] == "live")
    #expect(try await helper.state() == "running")
    #expect(Array(helper.backend.recordedCalls.suffix(3)) == ["pause", "saveState", "resume"])
    #expect(helper.stateFiles().isEmpty)  // the state went into the snapshot
    let id = try #require(meta["id"]?.stringValue)
    let snapshotState = helper.bundle.snapshotsDirectory.appendingPathComponent("\(id)/state")
    #expect(try FileManager.default.contentsOfDirectory(atPath: snapshotState.path).sorted() == ["suspend.json", "suspend.scripted"])

    // Restoring while running: forced off, disks swapped, resumed from the snapshot's memory.
    let restored = try await helper.client.call("vm.snapshot.restore", params: ["id": .string(id)])
    #expect(restored["resumed"] == true)
    #expect(restored["state"] == "running")
    #expect(Array(helper.backend.recordedCalls.suffix(2)) == ["stop.force", "start.resume"])
    #expect(helper.stateFiles().isEmpty)
    await helper.tearDown()
}

@Test func failedLiveSnapshotResumesAndLeavesNothing() async throws {
    let helper = try await Harness.make()
    _ = try await helper.client.call("vm.start")
    helper.backend.failOnce("saveState")
    await #expect(throws: RPCError.self) { try await helper.client.call("vm.snapshot.create", params: ["name": "x", "kind": "live"]) }
    #expect(try await helper.state() == "running")
    #expect(helper.backend.recordedCalls.last == "resume")
    #expect(try await helper.client.call("vm.snapshot.list") == .array([]))
    #expect(helper.stateFiles().isEmpty)
    await helper.tearDown()
}

@Test func diskSnapshotOfARunningVMIsRefused() async throws {
    let helper = try await Harness.make()
    _ = try await helper.client.call("vm.start")
    do {
        _ = try await helper.client.call("vm.snapshot.create", params: ["name": "d", "kind": "disk"])
        Issue.record("expected unsupportedLive")
    } catch let error as RPCError {
        #expect(error.knownCode == .unsupportedLive)
    }
    await helper.tearDown()
}

@Test func restoringADiskSnapshotOfAStoppedVMStaysStopped() async throws {
    let helper = try await Harness.make()
    let meta = try await helper.client.call("vm.snapshot.create", params: ["name": "d", "kind": "disk"])
    let restored = try await helper.client.call("vm.snapshot.restore", params: ["id": meta["id"] ?? .null])
    #expect(restored["state"] == "stopped")
    #expect(restored["resumed"] == nil)
    #expect(!helper.backend.recordedCalls.contains { $0.hasPrefix("start") })
    await helper.tearDown()
}
