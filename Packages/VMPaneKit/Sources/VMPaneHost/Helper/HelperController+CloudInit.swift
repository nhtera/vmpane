import Foundation
import VMPaneControl
import VMPaneCore

/// A Linux VM's first boot from a cloud image (`CloudImageInstall`): `install.progress` while cloud-init sets it up,
/// and once VMPane's guest tools connect (the seed's last step installs them) the seed goes, from the config and the
/// bundle: its user-data holds the password's hash.
extension HelperController {
    /// What `install.progress` says while the first boot runs; nil when this is no cloud image's first boot.
    func cloudInitProgress() -> JSONValue? {
        guard config.install?.cloudInit != nil, !CloudImageInstall.isUsed(prepared.lock.bundle), state == .running || state == .paused
        else { return nil }
        let message =
            config.install?.desktop == true
            ? "First boot: installing the desktop (several minutes; the VM restarts once)"
            : "First boot: setting up the system and VMPane's guest tools"
        return ["phase": "install", "percent": 50, "message": .string(message)]
    }

    /// The VM started: say what the first boot is doing.
    func cloudInitStarted() {
        guard let progress = cloudInitProgress() else { return }
        server?.broadcast(topic: "install", method: ControlNotification.installProgress.rawValue, params: progress)
    }

    /// The guest tools connected: the first boot is done, and the seed's data goes now (`CloudImageInstall.consume`);
    /// its device leaves the config when the VM next stops.
    func cloudInitReady() async {
        let bundle = prepared.lock.bundle
        guard config.install?.cloudInit != nil, !CloudImageInstall.isUsed(bundle) else { return }
        do {
            try await Blocking.run { try CloudImageInstall.consume(bundle) }
        } catch {
            Self.log.error("cannot remove the cloud-init seed: \(String(describing: error), privacy: .public)")
            return
        }
        Self.log.notice("first boot done: the cloud-init seed is removed")
        let message =
            config.install?.desktop == true
            ? "Ready: VMPane's guest tools are running; the VM restarts once into its desktop" : "Ready: VMPane's guest tools are running"
        server?.broadcast(
            topic: "install", method: ControlNotification.installProgress.rawValue,
            params: ["phase": "complete", "percent": 100, "message": .string(message)])
    }
}
