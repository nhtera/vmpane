import Foundation
import VMPaneCore

/// Where one QEMU VM's files live: the bundle (disks, firmware variables, TPM state, logs), the run directory
/// `run/<sid>/` (sockets, the per-start firmware code copy) and the QEMU installation (programs, firmware).
public struct QEMULayout: Sendable, Equatable {
    public var bundle: VMBundle
    public var runDirectory: URL
    public var installation: QEMUInstallation

    public init(bundle: VMBundle, runDirectory: URL, installation: QEMUInstallation) {
        self.bundle = bundle
        self.runDirectory = runDirectory
        self.installation = installation
    }

    /// Firmware code, padded to the flash size for this start (the shipped file is not).
    public var firmwareCode: URL { runDirectory.appendingPathComponent("efi_code.fd") }
    /// The VM's UEFI variables (Secure Boot keys, boot entries), part of its state like a disk.
    public var efiVariables: URL { bundle.auxDirectory.appendingPathComponent("efi_vars.fd") }
    public var tpmState: URL { bundle.auxDirectory.appendingPathComponent("tpm", isDirectory: true) }

    public var qmpSocket: URL { runDirectory.appendingPathComponent("qmp.sock") }
    public var tpmSocket: URL { runDirectory.appendingPathComponent("tpm.sock") }
    public var spiceSocket: URL { runDirectory.appendingPathComponent("spice.sock") }
    /// The VMPane guest agent's virtio-serial port (Phase 07).
    public var agentSocket: URL { runDirectory.appendingPathComponent("agent.sock") }

    public var qemuLog: URL { bundle.logsDirectory.appendingPathComponent("qemu.log") }
    public var swtpmLog: URL { bundle.logsDirectory.appendingPathComponent("swtpm.log") }

    /// The shipped firmware: code and the Secure Boot variable template (MS KEK/db enrolled).
    public var shippedFirmwareCode: URL { installation.share.appendingPathComponent("edk2-aarch64-code.fd") }
    public var shippedVariablesTemplate: URL { installation.share.appendingPathComponent("edk2-aarch64-vars-sb.fd") }
    /// QEMU's own data (option ROMs, keymaps), passed with `-L`.
    public var qemuData: URL { installation.share.appendingPathComponent("qemu", isDirectory: true) }

    /// Unix sockets QEMU or swtpm bind; each must fit `sun_path`.
    public var sockets: [URL] { [qmpSocket, tpmSocket, spiceSocket, agentSocket] }
}
