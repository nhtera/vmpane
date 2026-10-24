import AppKit
import Foundation
import VMPaneControl
import VMPaneCore

/// What the window knows of the VM's guest tools, for the banner that offers to install them.
public struct GuestToolsState: Equatable, Sendable {
    /// The agent is older than this VMPane (`agent.status`'s `outdated`).
    public var outdated = false
    /// The VM has run a while (90 s) without its agent.
    var waited = false
    /// Asked for from the menu: shown even when dismissed for this VM.
    var requested = false
    /// Closed in this window.
    var closed = false
    /// A Windows VM's tools disc is attached for its next start.
    public var discAttached = false
    /// An install (or a cloud image's first boot) is not done (`vm.info`'s `installing`): no offer then.
    var installing = false
    /// A QEMU VM: a Linux one there has no `vmpane-tools` share to install from.
    var shareless = false
}

/// The banner the window shows: how to install the tools (a VM without them) or update them by hand (macOS).
public enum GuestToolsBanner: Equatable, Sendable {
    case install(GuestOS)
    case updateByHand
}

/// The guest tools a VM lacks: macOS VMs, Linux VMs installed from an ISO and imported VMs have none until the
/// person installs them once (their updates come by themselves after that, except on macOS). The window offers
/// it once the VM has run a while without them, never during an install; Don't Ask Again holds for the VM.
extension HelperViewModel {
    static let toolsWait = 90
    /// Mounts the tools' shared folder and installs them (Linux).
    public static let linuxToolsCommand =
        "sudo mkdir -p /mnt/vmpane-tools && (mountpoint -q /mnt/vmpane-tools || sudo mount -t virtiofs vmpane-tools /mnt/vmpane-tools)"
        + " && sudo /mnt/vmpane-tools/install.sh"
    /// Runs the Windows tools disc's installer (D: is the VMPANE_TOOLS drive).
    public static let windowsToolsCommand = #"powershell -NoProfile -ExecutionPolicy Bypass -File D:\install.ps1"#

    var toolsDismissedKey: String { "guestToolsBannerDismissed.\(vmID ?? "?")" }

    /// The banner to show now, if any.
    public var toolsBanner: GuestToolsBanner? {
        guard let os, state == .running, install?.isActive != true, !guestTools.installing, !guestTools.closed,
            !(os == .linux && guestTools.shareless)
        else { return nil }
        let wanted = guestTools.requested || !UserDefaults.standard.bool(forKey: toolsDismissedKey)
        if agentConnected { return os == .macos && guestTools.outdated && wanted ? .updateByHand : nil }
        return wanted && (guestTools.waited || guestTools.requested) ? .install(os) : nil
    }

    /// Reads whether the agent is older than this VMPane (whether it runs comes with `agent.connectionChanged`).
    func refreshGuestTools() async {
        let status = try? await channel.call(ControlMethod.agentStatus.rawValue, params: nil, timeout: .seconds(5))
        guestTools.outdated = status?["connected"] == true && status?["outdated"] == true
    }

    /// Counts how long the VM runs without its agent (every 5 s), for `toolsBanner`.
    public func watchGuestTools() async {
        var alone = 0
        while !Task.isCancelled {
            let lonely = state == .running && !agentConnected && install?.isActive != true && !guestTools.installing
            alone = lonely ? alone + 5 : 0
            if alone >= Self.toolsWait, !guestTools.waited { guestTools.waited = true }
            if state != .running, guestTools.waited { guestTools.waited = false }  // a new run waits again
            try? await Task.sleep(for: .seconds(5))
        }
    }

    /// Install Guest Tools… in the menu: the banner, even if dismissed (while the VM runs without its tools).
    public func showToolsBanner() {
        guard state == .running else { return notice = "Start the VM, then install its guest tools" }
        guard !agentConnected || (os == .macos && guestTools.outdated) else { return notice = "The guest tools are installed" }
        guestTools.requested = true
        guestTools.closed = false
    }

    /// Not Now (`forever`: Don't Ask Again for this VM).
    public func closeToolsBanner(forever: Bool) {
        guestTools.closed = true
        guestTools.requested = false
        if forever { UserDefaults.standard.set(true, forKey: toolsDismissedKey) }
    }

    /// Types the Linux command into the VM (into the terminal the person opened); Return is theirs to press.
    public func typeToolsCommand() async {
        do {
            _ = try await channel.call(
                ControlMethod.vmInputText.rawValue, params: ["text": .string(Self.linuxToolsCommand)], timeout: .seconds(30))
        } catch {
            lastError = ErrorText.readable(error)
        }
    }

    public func copyToolsCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Self.linuxToolsCommand, forType: .string)
        notice = "Command copied"
    }

    /// Attaches a Windows VM's tools disc from its next boot.
    public func attachToolsDisc() async {
        do {
            _ = try await channel.call(ControlMethod.vmToolsAttach.rawValue, params: nil, timeout: .seconds(60))
            guestTools.discAttached = true
        } catch {
            lastError = ErrorText.readable(error)
        }
    }

    /// Update Guest Tools in the menu: an older Linux or Windows agent updates now; a macOS VM shows how; a VM
    /// without the tools shows how to install them.
    public func updateGuestTools() async {
        guard agentConnected else { return showToolsBanner() }
        guard state == .running else { return }
        await refreshGuestTools()
        guard guestTools.outdated else {
            notice = "The guest tools are up to date"
            return
        }
        if os == .macos { return showToolsBanner() }
        do {
            _ = try await channel.call(ControlMethod.vmToolsUpdate.rawValue, params: nil, timeout: .seconds(10))
        } catch {
            lastError = ErrorText.readable(error)
        }
    }
}
