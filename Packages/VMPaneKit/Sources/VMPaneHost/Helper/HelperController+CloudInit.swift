import Foundation
import VMPaneControl
import VMPaneCore

/// A Linux VM's first boot from a cloud image (`CloudImageInstall`), or Omarchy's autoinstall from its ISO
/// (`OmarchyInstall`): `install.progress` while it runs, and once it is done (the guest tools connect: the seed's last
/// step installs them; or the autoinstall's boot loader is in place) the seed goes, from the config and the bundle: it
/// holds the password's hash.
extension HelperController {
    /// An autoinstall: an ISO with a seed, rather than a cloud image's first boot.
    var isAutoinstall: Bool { config.install?.media != nil && config.install?.cloudInit != nil }

    /// What `install.progress` says while the first boot runs; nil when this is no cloud image's first boot.
    func cloudInitProgress() -> JSONValue? {
        guard config.install?.cloudInit != nil, !CloudImageInstall.isUsed(prepared.lock.bundle), state == .running || state == .paused
        else { return nil }
        let message =
            if isAutoinstall {
                "Installing the system from its ISO, with nothing to click (a few minutes; the VM then restarts into it)"
            } else if config.install?.desktop == true {
                "First boot: installing the desktop (several minutes; the VM restarts once)"
            } else {
                "First boot: setting up the system and VMPane's guest tools"
            }
        return ["phase": "install", "percent": 50, "message": .string(message)]
    }

    /// The VM started: say what the first boot is doing, and watch an autoinstall for its end.
    func cloudInitStarted() {
        guard let progress = cloudInitProgress() else { return }
        server?.broadcast(topic: "install", method: ControlNotification.installProgress.rawValue, params: progress)
        guard isAutoinstall else { return }
        installWatch?.cancel()
        installWatch = Task { await self.watchAutoinstall() }
    }

    /// An autoinstall's end, every few seconds while the VM runs: the installer registered its boot loader
    /// (`LinuxInstall.isInstalled`; the VM restarts into the system in place). The seed's data goes then, as nothing
    /// reads it any more; the ISO and the seed's device at the next stop. Installed from a stop, the tools are offered
    /// in the window as for any ISO install, and `cloudInitReady` says so when they connect.
    private func watchAutoinstall() async {
        let bundle = prepared.lock.bundle
        while !Task.isCancelled, state == .running || state == .paused, config.install?.cloudInit != nil,
            !CloudImageInstall.isUsed(bundle)
        {
            let config = self.config
            if await Blocking.run({ LinuxInstall.isInstalled(config, bundle: bundle) }) {
                guard await consumeSeed() else { return }
                Self.log.notice("autoinstall done: the boot loader is installed, the seed is removed")
                server?.broadcast(
                    topic: "install", method: ControlNotification.installProgress.rawValue,
                    params: [
                        "phase": "complete", "percent": 100,
                        "message": .string(
                            "Installed: the VM restarts into the system now. Sign in with your password; "
                                + "the window offers VMPane's guest tools."),
                    ])
                return
            }
            try? await Task.sleep(for: .seconds(5))
        }
    }

    /// The guest tools connected: the first boot is done, and the seed's data goes now (`CloudImageInstall.consume`);
    /// its device leaves the config when the VM next stops.
    func cloudInitReady() async {
        guard config.install?.cloudInit != nil, !CloudImageInstall.isUsed(prepared.lock.bundle), await consumeSeed() else { return }
        Self.log.notice("first boot done: the cloud-init seed is removed")
        let message =
            config.install?.desktop == true
            ? "Ready: VMPane's guest tools are running; the VM restarts once into its desktop" : "Ready: VMPane's guest tools are running"
        server?.broadcast(
            topic: "install", method: ControlNotification.installProgress.rawValue,
            params: ["phase": "complete", "percent": 100, "message": .string(message)])
    }

    /// Removes the seed's data (`CloudImageInstall.consume`); false, logged, when that fails.
    private func consumeSeed() async -> Bool {
        let bundle = prepared.lock.bundle
        do {
            try await Blocking.run { try CloudImageInstall.consume(bundle) }
            return true
        } catch {
            Self.log.error("cannot remove the cloud-init seed: \(String(describing: error), privacy: .public)")
            return false
        }
    }
}
