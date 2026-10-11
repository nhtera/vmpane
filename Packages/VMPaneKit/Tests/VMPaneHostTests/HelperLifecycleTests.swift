import Foundation
import Testing
import VMPaneControl
import VMPaneCore

@testable import VMPaneHost

/// A helper with a scripted backend on a real socket, in a short temp root.
struct Harness {
    let root: URL
    let paths: VMPanePaths
    let bundle: VMBundle
    let controller: HelperController
    let backend: ScriptedBackend
    let client: UDSClient

    static func make(
        memoryMiB: Int = 64, closeAction: UIConfig.CloseAction = .keepRunning,
        afterStop: (@Sendable (VMConfigV1) -> VMConfigV1?)? = nil, configure: (inout VMConfigV1) -> Void = { _ in }
    ) async throws -> Harness {
        let root = URL(fileURLWithPath: "/tmp/vp-l-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let paths = VMPanePaths(root: root.appendingPathComponent("s"))
        var config = VMConfigV1(VMConfigFields.new(name: "L", os: .linux, macAddress: MachineIdentity.randomMACAddress()))
        config.memory.mib = memoryMiB
        config.ui.closeAction = closeAction
        configure(&config)
        let bundle = try VMBundle.create(at: root.appendingPathComponent("L.vmpane"), config: config)
        let prepared = try LaunchCoordinator.prepareBundle(bundle, paths: paths, runtimeVersion: "t")
        let backend = ScriptedBackend()
        let controller = HelperController(
            prepared: prepared, runtimeVersion: "t", backend: backend, afterStop: afterStop
        ) {}
        await controller.setSessionLockCheck { false }  // independent of this Mac's real lock state
        await controller.setSpaceCheck { _, _ in }  // and of its free disk space
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

@Test func restoreFailingWhileTheMacIsLockedKeepsTheState() async throws {
    let helper = try await Harness.make()
    _ = try await helper.client.call("vm.start")
    _ = try await helper.client.call("vm.suspend")
    await helper.controller.setSessionLockCheck { true }
    helper.backend.failOnce("start.resume")
    do {
        _ = try await helper.client.call("vm.start")
        Issue.record("start succeeded while locked")
    } catch let error as RPCError {
        #expect(error.code == ControlErrorCode.macLocked.rawValue)
    }
    #expect(try await helper.state() == "stopped")
    #expect(helper.backend.recordedCalls.last == "start.resume")  // no cold boot
    #expect(helper.stateFiles() == ["suspend.json", "suspend.scripted"])
    // Unlocked: the kept state resumes.
    await helper.controller.setSessionLockCheck { false }
    _ = try await helper.client.call("vm.start")
    #expect(helper.backend.recordedCalls.last == "start.resume")
    #expect(helper.stateFiles().isEmpty)
    await helper.tearDown()
}

/// Detaches install media like `LinuxInstall.finished` would, once the install is done.
private let detachMedia: @Sendable (VMConfigV1) -> VMConfigV1? = { config in
    guard config.install != nil else { return nil }
    var config = config
    config.removable = []
    config.install = nil
    return config
}

func installing(_ config: inout VMConfigV1) {
    config.removable = [Extensible(RemovableConfig(id: "install", path: "/tmp/x.iso", bus: .usb))]
    config.install = Extensible(InstallConfig(media: "install"))
}

@Test func stopAppliesTheAfterStopHookForTheNextStart() async throws {
    let helper = try await Harness.make(afterStop: detachMedia, configure: installing)
    _ = try await helper.client.call("vm.start")
    helper.backend.emit(.stopped(reason: "guest shut down"))
    var saved = try ConfigStore.load(helper.bundle)
    for _ in 0..<100 where saved.install != nil {
        try await Task.sleep(for: .milliseconds(10))
        saved = try ConfigStore.load(helper.bundle)
    }
    #expect(saved.install == nil && saved.removable.isEmpty)
    #expect(try await helper.state() == "stopped")  // no restart
    _ = try await helper.client.call("vm.start")
    #expect(helper.backend.lastStartConfig?.removable.isEmpty == true)
    await helper.tearDown()
}

@Test func afterStopHookWaitsWhileSavedStateExists() async throws {
    let helper = try await Harness.make(afterStop: detachMedia, configure: installing)
    _ = try await helper.client.call("vm.start")
    _ = try await helper.client.call("vm.suspend")
    try await Task.sleep(for: .milliseconds(100))
    #expect(try ConfigStore.load(helper.bundle).install != nil)  // detaching would discard the suspend state
    #expect(helper.stateFiles() == ["suspend.json", "suspend.scripted"])
    await helper.tearDown()
}

@Test func backendReportedLockedStateIsKeptEvenWhenTheSessionLooksUnlocked() async throws {
    // A helper started outside the GUI session cannot see the screen lock; the backend's error decides.
    let helper = try await Harness.make()
    _ = try await helper.client.call("vm.start")
    _ = try await helper.client.call("vm.suspend")
    helper.backend.failOnce("start.resume", with: SavedStateLocked())
    do {
        _ = try await helper.client.call("vm.start")
        Issue.record("start succeeded")
    } catch let error as RPCError {
        #expect(error.code == ControlErrorCode.macLocked.rawValue)
    }
    #expect(helper.stateFiles() == ["suspend.json", "suspend.scripted"])
    await helper.tearDown()
}

@Test func liveSnapshotRestoreOnALockedMacIsRefusedBeforeStopping() async throws {
    let helper = try await Harness.make()
    _ = try await helper.client.call("vm.start")
    let meta = try await helper.client.call("vm.snapshot.create", params: ["name": "s", "kind": "live"])
    await helper.controller.setSessionLockCheck { true }
    await #expect(throws: RPCError.self) {
        try await helper.client.call("vm.snapshot.restore", params: ["id": meta["id"] ?? .null])
    }
    #expect(try await helper.state() == "running")
    #expect(!helper.backend.recordedCalls.contains("stop.force"))
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
    let helper = try await Harness.make()
    await helper.controller.setSpaceCheck { memory, _ in throw InsufficientSpace(requiredBytes: memory, availableBytes: 0) }
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

@Test func screenshotAndInputGoToTheBackendWhileRunning() async throws {
    let helper = try await Harness.make()
    await #expect(throws: RPCError.self) { try await helper.client.call("vm.screenshot") }  // stopped
    _ = try await helper.client.call("vm.start")
    let shot = try await helper.client.call("vm.screenshot", params: ["maxEdge": 800])
    #expect(shot["width"] == 4 && shot["height"] == 3 && shot["format"] == "png")
    #expect(shot["dataB64"]?.stringValue.flatMap { Data(base64Encoded: $0) } == Data([0x89, 0x50, 0x4E, 0x47]))
    _ = try await helper.client.call("vm.input.text", params: ["text": "Hello, World!"])
    _ = try await helper.client.call("vm.input.key", params: ["usage": 0x28, "down": true])
    _ = try await helper.client.call("vm.input.pointer", params: ["x": 10, "y": 20, "buttons": 1])
    _ = try await helper.client.call("vm.input.scroll", params: ["dy": -3])
    #expect(helper.backend.recordedCalls.filter { $0.hasPrefix("input.") }.count == 4)
    await #expect(throws: RPCError.self) { try await helper.client.call("vm.input.key", params: ["usage": "x"]) }  // bad params
    await helper.tearDown()
}

@Test func forceStopEscalatesAGracefulStopTheGuestIgnores() async throws {
    let helper = try await Harness.make()
    _ = try await helper.client.call("vm.start")
    helper.backend.ignoresGracefulStop = true
    #expect(try await helper.client.call("vm.stop", params: ["mode": "graceful"])["state"] == "stopping")
    _ = try await helper.client.call("vm.stop", params: ["mode": "force"])
    #expect(try await helper.waitForState("stopped"))
    await helper.tearDown()
}

@Test func shutdownForcesOffAVMStuckStopping() async throws {
    let helper = try await Harness.make()
    _ = try await helper.client.call("vm.start")
    helper.backend.ignoresGracefulStop = true
    _ = try await helper.client.call("vm.stop", params: ["mode": "graceful"])
    await helper.controller.setGracefulStopTimeout(.milliseconds(200))
    await helper.controller.shutdown()
    #expect(helper.backend.recordedCalls.last == "stop.force")
    #expect(try helper.bundle.tryLock(retryingFor: 1) != nil)
    try? FileManager.default.removeItem(at: helper.root)
}

@Test func stoppingLeavesAThumbnailForTheLibrary() async throws {
    let helper = try await Harness.make()
    _ = try await helper.client.call("vm.start")
    _ = try await helper.client.call("vm.stop", params: ["mode": "graceful"])
    #expect(try await helper.waitForState("stopped"))
    let thumbnail = helper.bundle.url.appendingPathComponent("thumbnail.png")
    #expect(try Data(contentsOf: thumbnail) == Data([0x89, 0x50, 0x4E, 0x47]))  // ScriptedBackend's screenshot
    await helper.tearDown()
}
