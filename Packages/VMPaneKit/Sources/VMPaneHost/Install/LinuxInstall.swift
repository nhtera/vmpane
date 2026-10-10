import Foundation
import VMPaneCore

public enum LinuxInstallError: Error, Equatable, Sendable {
    /// The ISO has no arm64 UEFI loader (likely an x86_64 image).
    case notArm64
    /// The ISO could not be mounted (damaged, or not an ISO).
    case unreadable
}

/// Linux install from an ISO: the ISO boots as read-only USB mass storage (`removable` entry
/// `install`, marked by `install.media`) and is detached at the first stop after the install finished.
public enum LinuxInstall {
    public static let mediaID = "install"

    /// `config` booting the catalog `image` (downloaded and sha256-checked into `cache` first).
    public static func prepare(
        _ config: VMConfigV1, image: ImageCatalog.Image, cache: ImageCache = .iso,
        progress: @escaping @Sendable (Int64, Int64?) -> Void = { _, _ in }
    ) async throws -> VMConfigV1 {
        let iso = try await cache.ensure(image, progress: progress)
        return try prepare(config, iso: iso)
    }

    /// `config` booting a local ISO, after checking it can boot an arm64 VM.
    public static func prepare(_ config: VMConfigV1, iso: URL) throws -> VMConfigV1 {
        switch ISOInspector.inspect(iso) {
        case .arm64: break
        case .notArm64: throw LinuxInstallError.notArm64
        case .unreadable: throw LinuxInstallError.unreadable
        }
        var config = config
        config.removable.removeAll { $0.id == mediaID }
        config.removable.append(Extensible(RemovableConfig(id: mediaID, path: iso.path, bus: .usb)))
        config.install = Extensible(InstallConfig(media: mediaID))
        return config
    }

    /// After the VM stopped: if it was installing and the install finished (the system disk has a partition
    /// table and the firmware has an OS boot entry, written when the boot loader is installed), the config
    /// without the installer media; else nil. Virtualization reboots Linux guests in place, so the installed
    /// system first runs with the media still attached; its boot entry comes first, so the ISO goes unused.
    public static func finished(_ config: VMConfigV1, bundle: VMBundle) -> VMConfigV1? {
        guard config.os == .linux, let media = config.install?.media, let disk = config.disks.first,
            let url = try? bundle.fileURL(relativePath: disk.file), DiskImage.hasPartitionTable(url),
            !DiskImage.efiBootLoaders(inVariableStore: bundle.auxDirectory.appendingPathComponent("efi_vars.fd")).isEmpty
        else { return nil }
        var config = config
        config.removable.removeAll { $0.id == media }
        config.install = nil
        return config
    }
}
