import Darwin
import Foundation
import Testing
import VMPaneControl
import VMPaneCore

@testable import VMPaneHost

/// The host end of the guest's agent port (QEMU's chardev socket): accepts the helper and writes lines to it.
private final class AgentPort: @unchecked Sendable {
    private let listener: Int32
    private let lock = NSLock()
    private var connection: Int32 = -1

    init(at socket: URL) throws {
        try FileManager.default.createDirectory(at: socket.deletingLastPathComponent(), withIntermediateDirectories: true)
        listener = try UnixSocket.make()
        try UnixSocket.bind(listener, to: .absolute(socket.path))
        listen(listener, 2)
        let listener = listener
        Thread { [weak self] in
            let fd = accept(listener, nil, nil)
            self?.lock.withLock { self?.connection = fd }
        }.start()
    }

    func send(_ line: String) async throws {
        for _ in 0..<200 where lock.withLock({ connection }) < 0 { try await Task.sleep(for: .milliseconds(10)) }
        try UnixSocket.writeAll(lock.withLock { connection }, Data((line + "\r\n").utf8))
    }

    deinit {
        close(listener)
        if connection >= 0 { close(connection) }
    }
}

/// `state` as `WindowsInstall.prepare` leaves it by default; nil: no state file at all.
private func installingHarness(state: InstallState? = InstallState()) async throws -> (Harness, AgentPort) {
    let harness = try await Harness.make(configure: { (config: inout VMConfigV1) in
        config.os = .windows
        config.qemu = Extensible(QEMUConfig(tpm: true, secureBoot: true, gpu: .ramfb, storageBus: .nvme, smbiosUUID: UUID()))
        config.removable = ["windows", "unattend", "tools"].map {
            Extensible(RemovableConfig(id: $0, path: "/install/\($0).iso", bus: .usb))
        }
        config.install = Extensible(InstallConfig(media: WindowsInstall.mediaID))
    })
    let prepared = await harness.controller.prepared
    if let state { try state.save(holding: prepared.lock) }
    try FileManager.default.createDirectory(at: harness.bundle.installDirectory, withIntermediateDirectories: true)
    try Data("password".utf8).write(to: UnattendMedia.url(in: harness.bundle))
    let timing = HelperController.InstallTiming(
        keyWindow: .milliseconds(300), keyInterval: .milliseconds(50), watchInterval: .milliseconds(100))
    await harness.controller.setInstallTiming(timing)
    let port = try AgentPort(at: prepared.runFiles.childDirectory.appendingPathComponent("agent.sock"))
    return (harness, port)
}

private func waitUntil(_ condition: () async throws -> Bool) async throws -> Bool {
    for _ in 0..<300 {
        if try await condition() { return true }
        try await Task.sleep(for: .milliseconds(20))
    }
    return false
}

@Test func windowsInstallRunsFromFirstBootToFinalize() async throws {
    let (helper, port) = try await installingHarness()
    defer { Task { await helper.tearDown() } }
    _ = try await helper.client.call("vm.start", params: ["headless": true])
    let bundle = helper.bundle

    // First boot: space presses, then Setup.
    #expect(try await waitUntil { InstallState.load(from: bundle)?.phase == .setupRunning })
    #expect(helper.backend.recordedCalls.contains { $0.hasPrefix("input.key(usage: 44, down: true)") })
    #expect(InstallState.load(from: bundle)?.attempts == 1)

    // Setup's first reboot ejects the Windows ISO, once.
    helper.backend.emit(.guestReset)
    #expect(try await waitUntil { InstallState.load(from: bundle)?.mediaEjected == true })
    #expect(try await waitUntil { try !ConfigStore.load(bundle).removable.contains { $0.id == WindowsInstall.mediaID } })
    helper.backend.emit(.guestReset)
    try await Task.sleep(for: .milliseconds(100))
    #expect(helper.backend.recordedCalls.filter { $0 == "eject.windows" }.count == 1)

    // The guest reports in; tools done → shutdown → finalize → started again without install media.
    try await port.send("VMPANE-INSTALL firstLogon")
    #expect(try await waitUntil { InstallState.load(from: bundle)?.phase == .firstLogon })
    try await port.send("something the guest made up")
    try await port.send("VMPANE-INSTALL toolsInstalled")
    #expect(try await waitUntil { InstallState.load(from: bundle)?.phase == .done })
    #expect(try await waitUntil { try await helper.state() == "running" })
    let config = try ConfigStore.load(bundle)
    #expect(config.install == nil && config.removable.isEmpty && config.qemu?.gpu == .virtio)
    #expect(helper.backend.recordedCalls.filter { $0 == "start" }.count == 2)
    #expect(helper.backend.recordedCalls.contains("stop.graceful"))
    #expect(!FileManager.default.fileExists(atPath: UnattendMedia.url(in: bundle).path))
}

/// A client that subscribes while the install runs (a window opened then) hears at once where it is, and can
/// cancel it: the VM stops without the unattend image.
@Test func aWindowOpenedDuringTheInstallSeesItAndCancelsIt() async throws {
    let (helper, _) = try await installingHarness()
    defer { Task { await helper.tearDown() } }
    _ = try await helper.client.call("vm.start", params: ["headless": true])
    let bundle = helper.bundle
    #expect(try await waitUntil { InstallState.load(from: bundle)?.phase == .setupRunning })

    _ = try await helper.client.call("events.subscribe", params: ["topics": ["install"]])
    var notes = helper.client.notifications.makeAsyncIterator()
    let now = await notes.next()
    #expect(now?.method == "install.progress" && now?.params?["phase"] == "install" && now?.params?["percent"] == 10)

    _ = try await helper.client.call("vm.install.cancel")
    // The phase's own announcement may still come first (it is sent after the state is saved).
    var cancelled = false
    for _ in 0..<5 where !cancelled {
        cancelled = await notes.next()?.params?["phase"] == "cancelled"
    }
    #expect(cancelled)
    #expect(try await waitUntil { try await helper.state() == "stopped" })
    #expect(!FileManager.default.fileExists(atPath: UnattendMedia.url(in: bundle).path))
}

/// A helper that restarts mid-Setup resumes without key presses, and a phase that runs out of time fails the
/// install: the unattend image goes at once, the install media at the next stop.
@Test func aResumedInstallPressesNoKeysAndTimesOut() async throws {
    var stale = InstallState(now: Date().addingTimeInterval(-4 * 3600))
    stale.advance(to: .firstBoot, now: Date().addingTimeInterval(-4 * 3600))
    stale.advance(to: .setupRunning, now: Date().addingTimeInterval(-3 * 3600))
    let (helper, _) = try await installingHarness(state: stale)
    defer { Task { await helper.tearDown() } }
    _ = try await helper.client.call("vm.start", params: ["headless": true])
    let bundle = helper.bundle

    #expect(try await waitUntil { InstallState.load(from: bundle)?.phase == .failed })
    #expect(!helper.backend.recordedCalls.contains { $0.hasPrefix("input.") })
    #expect(!FileManager.default.fileExists(atPath: UnattendMedia.url(in: bundle).path))
    #expect(try await helper.state() == "running")  // left for the user to finish by hand

    _ = try await helper.client.call("vm.stop", params: ["mode": "force"])
    #expect(try await waitUntil { (try? ConfigStore.load(bundle))?.install == nil })
    #expect(try ConfigStore.load(bundle).removable.isEmpty)
    #expect(InstallState.load(from: bundle)?.reason?.contains("in time") == true)
}

/// Setup may already have written the disk: a lost state file never means a fresh first boot (no key presses).
@Test func aLostStateFileResumesSetupWithoutKeyPresses() async throws {
    let (helper, _) = try await installingHarness(state: nil)
    defer { Task { await helper.tearDown() } }
    _ = try await helper.client.call("vm.start", params: ["headless": true])
    #expect(try await waitUntil { InstallState.load(from: helper.bundle)?.phase == .setupRunning })
    try await Task.sleep(for: .milliseconds(400))  // longer than the key window
    #expect(!helper.backend.recordedCalls.contains { $0.hasPrefix("input.") })
}

/// An install that failed while no helper saw the VM stop is cleaned up at the next start.
@Test func aFinishedInstallIsCleanedUpAtTheNextStart() async throws {
    var failed = InstallState()
    failed.end(.failed, reason: "timed out")
    let (helper, _) = try await installingHarness(state: failed)
    defer { Task { await helper.tearDown() } }
    _ = try await helper.client.call("vm.start", params: ["headless": true])
    let config = try ConfigStore.load(helper.bundle)
    #expect(config.install == nil && config.removable.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: UnattendMedia.url(in: helper.bundle).path))
    #expect(!helper.backend.recordedCalls.contains { $0.hasPrefix("input.") })
}

/// Tools installed, but the helper stopped before finalize: the next start finalizes first.
@Test func aPendingFinalizeRunsAtTheNextStart() async throws {
    var installed = InstallState()
    for phase in [InstallState.Phase.firstBoot, .setupRunning, .firstLogon, .toolsInstalled] { installed.advance(to: phase) }
    let (helper, _) = try await installingHarness(state: installed)
    defer { Task { await helper.tearDown() } }
    _ = try await helper.client.call("vm.start", params: ["headless": true])
    let config = try ConfigStore.load(helper.bundle)
    #expect(config.install == nil && config.removable.isEmpty && config.qemu?.gpu == .virtio)
    #expect(InstallState.load(from: helper.bundle)?.phase == .done)
    #expect(helper.backend.recordedCalls.filter { $0 == "start" }.count == 1)
}

/// Cancel takes both discs away from the running QEMU (a deleted image stays readable through its open file), ends
/// the install, stops the VM and cleans up.
@Test func cancellingEjectsTheDiscsAndStopsTheVM() async throws {
    let (helper, _) = try await installingHarness()
    defer { Task { await helper.tearDown() } }
    _ = try await helper.client.call("vm.start", params: ["headless": true])
    let bundle = helper.bundle
    #expect(try await waitUntil { InstallState.load(from: bundle)?.phase == .setupRunning })
    _ = try await helper.client.call("vm.install.cancel", params: [:])
    #expect(InstallState.load(from: bundle)?.phase == .cancelled)
    #expect(helper.backend.recordedCalls.contains("eject.windows") && helper.backend.recordedCalls.contains("eject.unattend"))
    #expect(!FileManager.default.fileExists(atPath: UnattendMedia.url(in: bundle).path))
    #expect(try await waitUntil { try await helper.state() == "stopped" })
    #expect(try await waitUntil { (try? ConfigStore.load(bundle))?.install == nil })
    await #expect(throws: (any Error).self) { _ = try await helper.client.call("vm.install.cancel", params: [:]) }
}

/// Setup holds the password in RAM and the disk holds its answers until the first sign-in: an installing VM is
/// neither suspended nor snapshotted.
@Test func anInstallingVMIsNeitherSuspendedNorSnapshotted() async throws {
    let (helper, _) = try await installingHarness()
    defer { Task { await helper.tearDown() } }
    _ = try await helper.client.call("vm.start", params: ["headless": true])
    for (method, params) in [("vm.suspend", [:]), ("vm.snapshot.create", ["name": "s", "kind": "live"])] as [(String, JSONValue)] {
        do {
            _ = try await helper.client.call(method, params: params)
            Issue.record("\(method) succeeded during an install")
        } catch {
            #expect(String(describing: error).contains("installing Windows"))
        }
    }
    #expect(try await helper.state() == "running")
    #expect(helper.stateFiles().isEmpty)
}
