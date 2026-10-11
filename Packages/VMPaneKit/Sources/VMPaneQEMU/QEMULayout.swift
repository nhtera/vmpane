import Foundation
import VMPaneCore

/// Where one QEMU VM's files live: the bundle (disks, firmware variables, TPM state, logs), the run directory
/// `run/<sid>/` (sockets, the per-start firmware code copy) and the QEMU installation (programs, firmware).
public struct QEMULayout: Sendable, Equatable {
    public var bundle: VMBundle
    /// The bundle directory every path QEMU and swtpm see is built from: `bundle.url`, or its real path
    /// after `resolved()` (`VMBundle` keeps a standardized URL, which turns `/private/tmp` back into `/tmp`).
    public private(set) var bundleDirectory: URL
    public var runDirectory: URL
    public var installation: QEMUInstallation

    public init(bundle: VMBundle, runDirectory: URL, installation: QEMUInstallation) {
        self.bundle = bundle
        bundleDirectory = bundle.url
        self.runDirectory = runDirectory
        self.installation = installation
    }

    /// A file of the bundle given by a config path (`disks[].file`), checked by `VMBundle.fileURL`.
    public func bundleFile(_ relativePath: String) throws -> URL {
        _ = try bundle.fileURL(relativePath: relativePath)
        return bundleDirectory.appendingPathComponent(relativePath)
    }

    /// `url` (a directory of the bundle, as the helper names it) under `bundleDirectory`, so QEMU gets the real path.
    public func path(of url: URL) -> URL {
        let base = bundle.url.standardizedFileURL.path, path = url.standardizedFileURL.path
        guard path.hasPrefix(base + "/") else { return url }
        return bundleDirectory.appendingPathComponent(String(path.dropFirst(base.count + 1)), isDirectory: url.hasDirectoryPath)
    }

    /// A removable medium (an absolute path) as QEMU must open it: inside the bundle (mapped to its real path) or
    /// the QEMU runtime copy (read-only firmware, guest tools). The sandbox would deny anything else.
    public func mediaFile(_ path: String) throws -> URL {
        // Standardized on both sides (`..` resolved; Foundation shows /private/tmp as /tmp either way).
        let file = URL(fileURLWithPath: path).standardizedFileURL.path
        for base in [bundleDirectory, bundle.url] {
            let prefix = base.standardizedFileURL.path + "/"
            if file.hasPrefix(prefix) { return bundleDirectory.appendingPathComponent(String(file.dropFirst(prefix.count))) }
        }
        if file.hasPrefix(installation.root.standardizedFileURL.path + "/") { return URL(fileURLWithPath: path) }
        throw QEMUConfigError.mediaOutsideBundle(path)
    }

    private var aux: URL { bundleDirectory.appendingPathComponent("current/aux", isDirectory: true) }
    private var logs: URL { bundleDirectory.appendingPathComponent("logs", isDirectory: true) }

    /// Firmware code, padded to the flash size for this start (the shipped file is not).
    public var firmwareCode: URL { runDirectory.appendingPathComponent("efi_code.fd") }
    /// The VM's UEFI variables (Secure Boot keys, boot entries), part of its state like a disk.
    public var efiVariables: URL { aux.appendingPathComponent("efi_vars.fd") }
    public var tpmState: URL { aux.appendingPathComponent("tpm", isDirectory: true) }

    public var qmpSocket: URL { runDirectory.appendingPathComponent("qmp.sock") }
    public var tpmSocket: URL { runDirectory.appendingPathComponent("tpm.sock") }
    public var spiceSocket: URL { runDirectory.appendingPathComponent("spice.sock") }
    /// The VMPane guest agent's virtio-serial port (Phase 07).
    public var agentSocket: URL { runDirectory.appendingPathComponent("agent.sock") }
    /// swtpm's state directory as swtpm is given it, from `runDirectory` (it cannot escape commas in a path).
    public var tpmStateLink: URL { runDirectory.appendingPathComponent("tpmstate") }

    /// A socket of `runDirectory` as QEMU and swtpm are given it: its full path, or its name when the full path
    /// does not fit `sun_path` (both run with `runDirectory` as their working directory; the helper's own
    /// connections fall back the same way, see `UnixSocketAddress`).
    public func socketArgument(_ socket: URL) -> String {
        socket.path.utf8.count <= QEMUArgvBuilder.maxSocketPathLength ? socket.path : socket.lastPathComponent
    }

    public var qemuLog: URL { logs.appendingPathComponent("qemu.log") }
    public var swtpmLog: URL { logs.appendingPathComponent("swtpm.log") }

    /// The shipped firmware: code and the Secure Boot variable template (MS KEK/db enrolled).
    public var shippedFirmwareCode: URL { installation.share.appendingPathComponent("edk2-aarch64-code.fd") }
    public var shippedVariablesTemplate: URL { installation.share.appendingPathComponent("edk2-aarch64-vars-sb.fd") }
    /// QEMU's own data (option ROMs, keymaps), passed with `-L`.
    public var qemuData: URL { installation.share.appendingPathComponent("qemu", isDirectory: true) }

    /// The same layout with symlinks resolved: sandbox rules match real paths, so the paths QEMU and swtpm
    /// are given must be real too (`/tmp` is a symlink to `/private/tmp`). The directories must exist.
    public func resolved() throws -> QEMULayout {
        var layout = QEMULayout(
            bundle: bundle, runDirectory: URL(fileURLWithPath: try QEMUSandbox.realPath(runDirectory), isDirectory: true),
            installation: QEMUInstallation(
                root: URL(fileURLWithPath: try QEMUSandbox.realPath(installation.root), isDirectory: true), source: installation.source))
        layout.bundleDirectory = URL(fileURLWithPath: try QEMUSandbox.realPath(bundleDirectory), isDirectory: true)
        return layout
    }

    /// Unix sockets QEMU or swtpm bind (see `socketArgument`).
    public var sockets: [URL] { [qmpSocket, tpmSocket, spiceSocket, agentSocket] }
}
