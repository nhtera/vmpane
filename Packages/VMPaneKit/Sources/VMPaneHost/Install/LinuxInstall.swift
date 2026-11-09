import Foundation
import VMPaneCore

public enum LinuxInstallError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The ISO has no arm64 UEFI loader (likely an x86_64 image).
    case notArm64
    /// The ISO could not be read (damaged, or not an ISO).
    case unreadable

    public var description: String {
        switch self {
        case .notArm64: "this ISO has no arm64 boot loader (EFI/BOOT/BOOTAA64.EFI): choose the arm64 (aarch64) edition"
        case .unreadable: "the ISO cannot be read (it may be damaged, or not an ISO image)"
        }
    }
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

    /// Before installing into a VM that already has a system: forgets the firmware's boot entries, so the
    /// installer ISO boots instead of the old system (and `finished` does not see the old entry).
    public static func forgetBootEntries(holding lock: BundleLock) throws {
        let store = lock.bundle.auxDirectory.appendingPathComponent("efi_vars.fd")
        guard FileManager.default.fileExists(atPath: store.path) else { return }
        try FileManager.default.removeItem(at: store)
        try DurableWrite.syncDirectory(lock.bundle.auxDirectory)
    }

    /// Whether the install into `config`'s disk finished: the disk has a partition table and the firmware an OS boot
    /// entry (written when the boot loader is installed, the installer's last step). Readable while the VM runs: the
    /// firmware's variable store is kept up to date on disk.
    public static func isInstalled(_ config: VMConfigV1, bundle: VMBundle) -> Bool {
        guard config.os == .linux, let disk = config.disks.first, let url = try? bundle.fileURL(relativePath: disk.file),
            DiskImage.hasPartitionTable(url)
        else { return false }
        return !DiskImage.efiBootLoaders(inVariableStore: bundle.auxDirectory.appendingPathComponent("efi_vars.fd")).isEmpty
    }

    /// After the VM stopped: if it was installing and the install finished (`isInstalled`), the config without the
    /// installer media; else nil. Virtualization reboots Linux guests in place, so the installed system first runs
    /// with the media still attached; its boot entry comes first, so the ISO goes unused. An autoinstall's seed record
    /// (`install.cloudInit`, `OmarchyInstall`) stays until its device goes (`CloudImageInstall.finished`).
    public static func finished(_ config: VMConfigV1, bundle: VMBundle) -> VMConfigV1? {
        guard let media = config.install?.media, isInstalled(config, bundle: bundle) else { return nil }
        var config = config
        config.removable.removeAll { $0.id == media }
        if config.install?.cloudInit == nil { config.install = nil } else { config.install?.media = nil }
        return config
    }
}
