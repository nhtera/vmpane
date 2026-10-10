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

private func installingHarness(state: InstallState? = nil) async throws -> (Harness, AgentPort) {
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
