import Darwin
import Foundation
import Testing
import VMPaneCore

@testable import VMPaneQEMU

// Opt-in (VMPANE_QEMU_BUNDLE=<build/qemu-bundle>): the backend runs the shipped QEMU and swtpm sandboxed, on
// a Windows config with an empty disk (the firmware runs; no OS needed).

private let qemuBundle = ProcessInfo.processInfo.environment["VMPANE_QEMU_BUNDLE"]

/// Spawns without a run directory record, remembering every child for the checks and the clean-up.
private final class Spawner: @unchecked Sendable {
    private let lock = NSLock()
    private var spawned: [ProcessRecord] = []

    func spawn(_ executable: URL, _ options: ChildSpawner.Options) throws -> ProcessRecord {
        let record = try ChildSpawner.spawn(executable, options)
        lock.withLock { spawned.append(record) }
        return record
    }

    var children: [ProcessRecord] { lock.withLock { spawned } }
}

private final class Harness: @unchecked Sendable {
    let root: URL
    let backend: QEMUBackend
    let layout: QEMULayout
    let bundleLock: BundleLock
    let config: VMConfigV1
    private let spawner = Spawner()
    private let lock = NSLock()
    private var eventLog: [BackendEvent] = []

    init(memoryMiB: Int = 1024, space: QEMUBackend.SpacePolicy = .standard, change: (inout VMConfigV1) -> Void = { _ in }) throws {
        // Through the /tmp symlink on purpose: the backend must hand QEMU resolved paths (sandbox rules match them).
        root = URL(fileURLWithPath: "/tmp/vp-be-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let run = root.appendingPathComponent("run", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var config = try windowsConfig()
        config.memory.mib = memoryMiB
        config.audio.output = false
        change(&config)
        self.config = config
        let bundle = try VMBundle.create(at: root.appendingPathComponent("W.vmpane"), config: config)
        try DiskImage.createRaw(at: bundle.currentDirectory.appendingPathComponent("disk.img"), sizeBytes: 1 << 30)
        let installation = QEMUInstallation(root: URL(fileURLWithPath: try #require(qemuBundle), isDirectory: true), source: .environment)
        layout = QEMULayout(bundle: bundle, runDirectory: run, installation: installation)
        bundleLock = try #require(try bundle.tryLock(retryingFor: 5))
        let spawner = spawner
        let processes = QEMUProcesses(
            layout: layout, lockDescriptor: bundleLock.fileDescriptor, spawn: { try spawner.spawn($0, $1) }, forget: { _ in })
        backend = QEMUBackend(config: config, processes: processes, space: space, resolveInstallation: { installation })
        let events = backend.events
        Task { [weak self] in
            for await event in events { self?.record(event) }
        }
    }

    private func record(_ event: BackendEvent) { lock.withLock { eventLog.append(event) } }

    var children: [ProcessRecord] { spawner.children }
    var anyChildAlive: Bool { children.contains { $0.isAlive } }
    var events: [BackendEvent] { lock.withLock { eventLog } }

    func waitForEvent(timeout: TimeInterval = 20, _ match: (BackendEvent) -> Bool) async -> BackendEvent? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let event = events.first(where: match) { return event }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return nil
    }

    func cleanUp() {
        for child in children { child.terminate() }
        try? FileManager.default.removeItem(at: root)
    }
}

@Test(.enabled(if: qemuBundle != nil))
func backendRunsSandboxedAndForceStops() async throws {
    let harness = try Harness()
    defer { harness.cleanUp() }
    try await harness.backend.start(StartOptions(headless: true))
    #expect(harness.children.count == 2)  // swtpm, then QEMU, both through sandbox-exec
    for child in harness.children {
        #expect(child.executablePath.isEmpty)  // recorded by pid + start time
        #expect(ProcessRecord.current(pid: child.pid)?.executablePath.hasPrefix(harness.layout.installation.root.path) == true)
    }
    let qmp = try #require(await harness.backend.qmp)
    #expect(try await qmp.execute("query-status")["status"] == "running")
    #expect(try await qmp.execute("query-tpm").array?.count == 1)

    // Something on the display (the firmware, or QEMU's "not initialized" placeholder before it): the screendump pipeline works.
    var shot: Screenshot?
    for _ in 0..<40 {
        let pixels = try await harness.backend.screenshotPixels()
        if !QEMUScreenshot.isBlack(pixels) {
            shot = try await harness.backend.screenshot(maxEdge: 400)
            break
        }
        try await Task.sleep(for: .milliseconds(250))
    }
    #expect(shot?.width == 400)
    try await harness.backend.send(.key(usage: 0x29, down: true))
    try await harness.backend.send(.key(usage: 0x29, down: false))
    try await harness.backend.send(.pointer(x: 10, y: 10, buttons: 0))

    try await harness.backend.pause()
    #expect(await harness.waitForEvent { $0 == .paused } != nil)
    try await harness.backend.resume()
    #expect(await harness.waitForEvent { $0 == .resumed } != nil)

    try await harness.backend.stop(.force)
    #expect(await harness.waitForEvent { $0 == .stopped(reason: "forced off") } != nil)
    for _ in 0..<100 where harness.anyChildAlive { try await Task.sleep(for: .milliseconds(50)) }
    #expect(!harness.anyChildAlive)  // swtpm --terminate followed QEMU
}

@Test(.enabled(if: qemuBundle != nil))
func losingTheTPMStopsTheVM() async throws {
    let harness = try Harness()
    defer { harness.cleanUp() }
    try await harness.backend.start(StartOptions(headless: true))
    let swtpm = try #require(harness.children.first)
    kill(swtpm.pid, SIGTERM)
    let failed = await harness.waitForEvent {
        if case .failed = $0 { return true }
        return false
    }
    #expect(
        failed == .failed(message: "The VM's TPM emulator stopped (exited with status 0); the VM was powered off to protect its TPM state.")
    )
    for _ in 0..<100 where harness.anyChildAlive { try await Task.sleep(for: .milliseconds(50)) }
    #expect(!harness.anyChildAlive)
}

@Test(.enabled(if: qemuBundle != nil))
func aQEMUThatCannotStartFailsWithItsLog() async throws {
    let harness = try Harness(memoryMiB: 1 << 30)  // 1 PiB of RAM: QEMU refuses at once
    defer { harness.cleanUp() }
    do {
        try await harness.backend.start(StartOptions(headless: true))
        Issue.record("started")
    } catch QEMUStartError.exitedDuringStart(let program, _, let log) {
        #expect(program == "QEMU" && !log.isEmpty)
    }
    for _ in 0..<100 where harness.anyChildAlive { try await Task.sleep(for: .milliseconds(50)) }
    #expect(!harness.anyChildAlive)  // swtpm stopped too
}

extension JSONValue {
    fileprivate var array: [JSONValue]? {
        if case .array(let values) = self { return values }
        return nil
    }
}

extension QEMUBackend {
    fileprivate func screenshotPixels() async throws -> QEMUScreenshot.Pixels { try await session.capture() }
}

@Test(.enabled(if: qemuBundle != nil))
func suspendThenResumeFromTheSavedState() async throws {
    let harness = try Harness()
    defer { harness.cleanUp() }
    let state = harness.layout.bundle.stateDirectory
    try await harness.backend.start(StartOptions(headless: true))
    try await Task.sleep(for: .seconds(1))  // the firmware runs

    // Live snapshot path: pause, save, continue.
    try await harness.backend.pause()
    try await harness.backend.saveState(to: state)
    #expect(FileManager.default.fileExists(atPath: state.appendingPathComponent(QEMUState.fileName).path))
    try await harness.backend.resume()
    #expect(try await harness.backend.qmp?.execute("query-status")["status"] == "running")
    for file in try FileManager.default.contentsOfDirectory(at: state, includingPropertiesForKeys: nil) {
        try FileManager.default.removeItem(at: file)
    }

    // Suspend: saved, renamed from .partial, QEMU and swtpm gone when it returns.
    try await harness.backend.suspend(to: state)
    #expect(try FileManager.default.contentsOfDirectory(atPath: state.path).sorted() == [QEMUState.fileName, QEMUState.infoName].sorted())
    #expect(!harness.anyChildAlive)
    #expect(await harness.waitForEvent { $0 == .stopped(reason: "suspended") } != nil)

    // Resume: a new swtpm and QEMU load the state and continue.
    try await harness.backend.start(StartOptions(headless: true, stateDirectory: state))
    #expect(try await harness.backend.qmp?.execute("query-status")["status"] == "running")
    try await harness.backend.stop(.force)
    #expect(await harness.waitForEvent { $0 == .stopped(reason: "forced off") } != nil)

    // State from another QEMU build is refused (the helper then cold-boots), leaving nothing running.
    try JSONEncoder().encode(QEMUState.Info(qemu: "10.0.0")).write(to: state.appendingPathComponent(QEMUState.infoName))
    await #expect(throws: QEMUStateError.incompatible(saved: "10.0.0", running: "11.1.2")) {
        try await harness.backend.start(StartOptions(headless: true, stateDirectory: state))
    }
    for _ in 0..<100 where harness.anyChildAlive { try await Task.sleep(for: .milliseconds(50)) }
    #expect(!harness.anyChildAlive)
}

/// Free space the test controls.
private final class FreeSpace: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: UInt64 = 100 << 30
    var value: UInt64 {
        get { lock.withLock { bytes } }
        set { lock.withLock { bytes = newValue } }
    }
}

@Test(.enabled(if: qemuBundle != nil))
func aNearlyFullVolumePausesTheGuestUntilSpaceIsFreed() async throws {
    let free = FreeSpace()
    let policy = QEMUBackend.SpacePolicy(pauseBelow: 2 << 30, resumeFrom: 3 << 30, interval: .milliseconds(100)) { _ in free.value }
    let harness = try Harness(space: policy)
    defer { harness.cleanUp() }
    try await harness.backend.start(StartOptions(headless: true))

    free.value = 1 << 30
    let full = await harness.waitForEvent(timeout: 5) {
        if case .diskFull = $0 { return true }
        return false
    }
    #expect(full == .diskFull(message: QEMUSession.diskFullMessage))
    #expect(try await harness.backend.qmp?.execute("query-status")["status"] == "paused")

    free.value = (5 << 29)  // 2.5 GiB: above the pause line, below the resume line
    await #expect(throws: InsufficientSpace(requiredBytes: 3 << 30, availableBytes: 5 << 29)) { try await harness.backend.resume() }
    free.value = 10 << 30
    try await harness.backend.resume()
    #expect(try await harness.backend.qmp?.execute("query-status")["status"] == "running")
    try await harness.backend.stop(.force)
}

@Test(.enabled(if: qemuBundle != nil))
func portForwardsChangeWhileRunning() async throws {
    func rule(_ id: String, _ port: Int) -> Extensible<PortForwardConfig> {
        Extensible(PortForwardConfig(id: id, proto: .tcp, hostAddress: "127.0.0.1", hostPort: port, guestPort: 22, origin: .user))
    }
    let harness = try Harness { $0.portForwards = [rule("a", 47_101)] }
    defer { harness.cleanUp() }
    try await harness.backend.start(StartOptions(headless: true))
    func usernet() async throws -> String {
        try await harness.backend.qmp?.execute("human-monitor-command", ["command-line": "info usernet"]).stringValue ?? ""
    }
    #expect(try await usernet().contains("47101"))

    var config = harness.config
    config.portForwards = [rule("b", 47_102)]
    #expect(await harness.backend.applyLive(config, paths: ["portForwards"]) == ["portForwards"])
    let table = try await usernet()
    #expect(table.contains("47102") && !table.contains("47101"))

    config.portForwards = [rule("c", 0)]  // invalid: nothing changes
    #expect(await harness.backend.applyLive(config, paths: ["portForwards"]).isEmpty)
    #expect(try await usernet().contains("47102"))
    try await harness.backend.stop(.force)
}
