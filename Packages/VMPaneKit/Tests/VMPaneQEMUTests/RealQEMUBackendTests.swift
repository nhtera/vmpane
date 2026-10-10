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
    private let spawner = Spawner()
    private let lock = NSLock()
    private var eventLog: [BackendEvent] = []

    init(memoryMiB: Int = 1024) throws {
        root = URL(fileURLWithPath: "/private/tmp/vp-be-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let run = root.appendingPathComponent("run", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var config = try windowsConfig()
        config.memory.mib = memoryMiB
        config.audio.output = false
        let bundle = try VMBundle.create(at: root.appendingPathComponent("W.vmpane"), config: config)
        try DiskImage.createRaw(at: bundle.currentDirectory.appendingPathComponent("disk.img"), sizeBytes: 1 << 30)
        let installation = QEMUInstallation(root: URL(fileURLWithPath: try #require(qemuBundle), isDirectory: true), source: .environment)
        layout = QEMULayout(bundle: bundle, runDirectory: run, installation: installation)
        bundleLock = try #require(try bundle.tryLock())
        let spawner = spawner
        let processes = QEMUProcesses(
            layout: layout, lockDescriptor: bundleLock.fileDescriptor, spawn: { try spawner.spawn($0, $1) }, forget: { _ in })
        backend = QEMUBackend(config: config, processes: processes, resolveInstallation: { installation })
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
