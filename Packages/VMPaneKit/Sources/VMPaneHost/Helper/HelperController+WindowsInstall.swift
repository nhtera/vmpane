import Foundation
import VMPaneControl
import VMPaneCore

/// The unattended Windows install, driven by the VM's own lifecycle and persisted in `install/install.json`
/// (Red Team #14): a helper that restarts picks it up where it was.
///
/// first boot: space bar every 0.5 s for 20 s ("Press any key to boot from CD"), only on a fresh first boot →
/// Setup: at its first reboot the Windows ISO is ejected (Setup can never start over) → the guest's install
/// script reports `firstLogon`, then `toolsInstalled` on the agent port → the VM shuts down → finalize: install
/// media and the unattend image (the password) are removed, the virtio display replaces ramfb, the NIC comes
/// back (no longer an install), and the VM starts again. A phase that runs out of time ends the install as
/// failed: the image is deleted at once and the VM is left for the user to finish by hand.
extension HelperController {
    /// Lines the guest's `install.ps1` writes to `\\.\Global\app.vmpane.agent.0`.
    static let installReports: [String: InstallState.Phase] = [
        "VMPANE-INSTALL firstLogon": .firstLogon, "VMPANE-INSTALL toolsInstalled": .toolsInstalled,
    ]
    /// How long and how often keys are pressed on the first boot, and how often timeouts are checked.
    struct InstallTiming: Sendable {
        var keyWindow = Duration.seconds(20)
        var keyInterval = Duration.milliseconds(500)
        var watchInterval = Duration.seconds(30)
    }

    func setInstallTiming(_ timing: InstallTiming) { installTiming = timing }

    var isInstallingWindows: Bool { config.os == .windows && config.install?.media == WindowsInstall.mediaID }

    /// Before a start: the persisted install, or a new one.
    func installWillStart() async {
        guard isInstallingWindows else { return }
        var state = windowsInstall ?? InstallState.load(from: prepared.lock.bundle) ?? InstallState()
        guard !state.isFinished else { return }
        if state.phase == .prepared { state.advance(to: .firstBoot) }
        await persistInstall(state)
    }

    /// After the VM started: key presses on a fresh first boot, the guest's reports, the timeouts.
    func installDidStart(_ backend: VMBackend) {
        guard let state = windowsInstall, !state.isFinished else { return }
        if installReader == nil {
            let reader = GuestLineReader(socket: prepared.runFiles.childDirectory.appendingPathComponent("agent.sock"))
            installReader = reader
            Task { [weak self] in
                for await line in reader.lines { await self?.installReport(line) }
            }
        }
        if installWatch == nil {
            installWatch = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: self?.installTiming.watchInterval ?? .seconds(30))
                    await self?.checkInstallTimeout()
                }
            }
        }
        if state.phase == .firstBoot {
            let timing = installTiming
            Task { [weak self] in
                let deadline = ContinuousClock.now + timing.keyWindow
                while ContinuousClock.now < deadline {
                    try? await backend.send(.key(usage: 0x2C, down: true))
                    try? await backend.send(.key(usage: 0x2C, down: false))
                    try? await Task.sleep(for: timing.keyInterval)
                }
                await self?.advanceInstall(to: .setupRunning)
            }
        }
    }

    /// Setup rebooted: from now on the disk must boot, never the ISO again.
    func installGuestReset() async {
        guard var state = windowsInstall, state.phase == .setupRunning, !state.mediaEjected, let backend else { return }
        do {
            try await backend.ejectMedia(WindowsInstall.mediaID)
            state.mediaEjected = true
            await persistInstall(state)
            announceInstall("Windows Setup restarted; the installer disc is ejected", percent: 30)
        } catch {
            Self.log.error("cannot eject the Windows ISO: \(String(describing: error), privacy: .public)")
        }
    }

    /// A line from the guest (untrusted): only the exact reports count.
    func installReport(_ line: String) async {
        guard let phase = Self.installReports[line] else { return }
        await advanceInstall(to: phase)
        if phase == .toolsInstalled, state == .running, let backend {
            // Finalize changes devices (NIC, display): QEMU must restart, so the guest shuts down first.
            transition(.stop)
            try? await backend.stop(.graceful)
        }
    }

    func advanceInstall(to phase: InstallState.Phase) async {
        guard var state = windowsInstall, !state.isFinished else { return }
        state.advance(to: phase)
        guard state != windowsInstall else { return }
        await persistInstall(state)
        let progress: [InstallState.Phase: (Int, String)] = [
            .setupRunning: (10, "Windows Setup is installing"), .firstLogon: (80, "Windows started; installing drivers and tools"),
            .toolsInstalled: (90, "Drivers and tools installed; restarting the VM"),
        ]
        if let (percent, message) = progress[phase] { announceInstall(message, percent: percent) }
    }

    /// The VM stopped during an install: finalize after the tools, clean up after a failure.
    func installStopped() async {
        guard var state = windowsInstall, let backend else { return }
        switch state.phase {
        case .toolsInstalled:
            var finalized = WindowsInstall.cleanUp(config, bundle: prepared.lock.bundle)
            finalized.qemu?.gpu = .virtio  // viogpudo is installed now
            guard await saveConfig(finalized) else { return }
            state.advance(to: .done)
            await persistInstall(state)
            stopInstallWatchers()
            announceInstall("Windows is installed", percent: 100)
            _ = try? await startVM(backend, headless: lastStartHeadless)
        case .failed, .cancelled:
            _ = await saveConfig(WindowsInstall.cleanUp(config, bundle: prepared.lock.bundle))
            stopInstallWatchers()
        default:
            break  // the user stopped the VM mid-install: it resumes at the next start
        }
    }

    func checkInstallTimeout() async {
        guard let state = windowsInstall, !state.isFinished, state.timedOut() else { return }
        await endInstall(.failed, reason: "Windows Setup did not reach \(state.phase.rawValue) in time")
    }

    /// Ends the install unsuccessfully: the unattend image (the password) is deleted now; the VM is left as it
    /// is for the user to finish by hand, and its install media go at the next stop.
    func endInstall(_ phase: InstallState.Phase, reason: String) async {
        guard var state = windowsInstall, !state.isFinished else { return }
        // The password goes first: whatever happens next, it is not left behind.
        let bundle = prepared.lock.bundle
        await Blocking.run { UnattendMedia.remove(from: bundle) }
        state.end(phase, reason: reason)
        await persistInstall(state)
        announceInstall("The automatic install stopped: \(reason). Finish it in the VM's window.", percent: 0, phase: "failed")
        if self.state == .stopped { await installStopped() }
    }

    private func persistInstall(_ state: InstallState) async {
        windowsInstall = state
        let lock = prepared.lock
        do {
            try await Blocking.run { try state.save(holding: lock) }
        } catch {
            Self.log.error("cannot save the install state: \(String(describing: error), privacy: .public)")
        }
    }

    private func saveConfig(_ updated: VMConfigV1) async -> Bool {
        let lock = prepared.lock
        do {
            try await Blocking.run { try ConfigStore.save(updated, holding: lock) }
            config = updated
            return true
        } catch {
            Self.log.error("cannot save the config after the install: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    private func stopInstallWatchers() {
        installReader?.stop()
        installReader = nil
        installWatch?.cancel()
        installWatch = nil
    }

    private func announceInstall(_ message: String, percent: Int, phase: String = "install") {
        server?.broadcast(
            topic: "install", method: ControlNotification.installProgress.rawValue,
            params: ["phase": .string(phase), "percent": .int(Int64(percent)), "message": .string(message)])
    }
}
