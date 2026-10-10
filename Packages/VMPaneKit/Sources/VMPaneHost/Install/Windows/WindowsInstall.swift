import Foundation
import VMPaneCore

public enum WindowsInstallError: Error, Equatable, Sendable, CustomStringConvertible {
    case notWindowsVM
    case notArm64
    case notWindows11(build: Int?)
    case notWindowsMedia
    case unreadable
    case editionMissing(String, available: [String])

    public var description: String {
        switch self {
        case .notWindowsVM: "this VM is not a Windows VM"
        case .notArm64: "this ISO is not Windows for ARM (VMPane runs the ARM64 edition of Windows 11)"
        case .notWindows11(let build):
            "this ISO is an older Windows (build \(build.map(String.init) ?? "unknown")); VMPane installs Windows 11"
        case .notWindowsMedia: "this ISO is not Windows install media"
        case .unreadable: "the ISO cannot be opened"
        case .editionMissing(let edition, let available): "\(edition) is not on this ISO (it has \(available.joined(separator: ", ")))"
        }
    }
}

/// An unattended Windows install, prepared in the VM bundle: the Windows ISO and the guest-tools ISO copied into
/// `install/` (an APFS clone when on the same volume: QEMU's sandbox reads only the bundle), the unattend image
/// built there, and the config set to boot the Windows ISO with no network. The password goes only into the
/// unattend image (0600, deleted by `cleanUp`), never into the config.
public enum WindowsInstall {
    public static let mediaID = "windows"
    public static let unattendID = "unattend"
    public static let toolsID = "tools"
    static let isoName = "windows.iso"
    static let toolsName = "guest-tools.iso"
    /// Free space Setup needs besides a copied ISO: the system it writes (12–15 GiB), with the disk-full
    /// watchdog's 2 GiB line and room for the first updates.
    public static let setupBytes: UInt64 = 20 << 30

    /// The guest-tools ISO in the app (`Contents/Resources/GuestTools`, from guest-tools/build-iso.sh), the
    /// `tools` argument of `prepare`; nil in a build without it.
    public static func bundledTools(app: URL = Bundle.main.bundleURL) -> URL? {
        let iso = app.appendingPathComponent("Contents/Resources/GuestTools/vmpane-guest-tools-windows.iso")
        return FileManager.default.fileExists(atPath: iso.path) ? iso : nil
    }

    public static func prepare(
        _ config: VMConfigV1, iso: URL, input: UnattendInput, tools: URL?, holding lock: BundleLock,
        freeBytes: (URL) throws -> UInt64 = SpaceGuard.freeBytes,
        inspect: (URL) -> WindowsISOInspector.Verdict = { WindowsISOInspector.inspect($0) }
    ) throws -> VMConfigV1 {
        guard config.os == .windows, config.backend == .qemu else { throw WindowsInstallError.notWindowsVM }
        let editions: [WindowsImage]
        switch inspect(iso) {
        case .windows11(let found): editions = found
        case .notArm64: throw WindowsInstallError.notArm64
        case .notWindows11(let build): throw WindowsInstallError.notWindows11(build: build)
        case .notWindows: throw WindowsInstallError.notWindowsMedia
        case .unreadable: throw WindowsInstallError.unreadable
        }
        guard editions.contains(where: { $0.name == input.editionName }) else {
            throw WindowsInstallError.editionMissing(input.editionName, available: editions.map(\.name))
        }
        let xml = try AutounattendGenerator.generate(input)  // validates the input before anything is copied

        let bundle = lock.bundle
        let sources = [iso] + (tools.map { [$0] } ?? [])
        let copied = sources.filter { !CloneFile.volumeSupportsCloning($0) || !sameVolume($0, bundle.url) }
        let needed = setupBytes + copied.reduce(0) { $0 + ((try? DiskImage.logicalSize($1)) ?? 0) }
        let free = try freeBytes(bundle.url)
        guard free >= needed else { throw InsufficientSpace(requiredBytes: needed, availableBytes: free) }

        try FileManager.default.createDirectory(
            at: bundle.installDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let installISO = try place(iso, as: isoName, in: bundle)
        let toolsISO = try tools.map { try place($0, as: toolsName, in: bundle) }
        let unattend = try UnattendMedia.build(xml, in: bundle)

        var config = config
        config.removable.removeAll { [mediaID, unattendID, toolsID].contains($0.id) }
        config.removable.append(Extensible(RemovableConfig(id: mediaID, path: installISO.path, bus: .usb)))
        config.removable.append(Extensible(RemovableConfig(id: unattendID, path: unattend.path, bus: .usb)))
        if let toolsISO { config.removable.append(Extensible(RemovableConfig(id: toolsID, path: toolsISO.path, bus: .usb))) }
        config.install = Extensible(InstallConfig(media: mediaID))
        // ramfb until viogpudo is installed (a second display before the driver leaves both black, S2).
        config.qemu?.gpu = .ramfb
        var windows = config.windows ?? Extensible(WindowsConfig())
        windows.eulaAcceptedAt = input.eulaAcceptedAt
        config.windows = windows
        return config
    }

    /// The single cleanup of every way an install ends (done, failed, cancelled): deletes the unattend image (the
    /// password) and the copied ISOs, and returns the config without install media. Safe to repeat.
    public static func cleanUp(_ config: VMConfigV1, bundle: VMBundle) -> VMConfigV1 {
        UnattendMedia.remove(from: bundle)
        for name in [isoName, toolsName] { try? FileManager.default.removeItem(at: bundle.installDirectory.appendingPathComponent(name)) }
        try? DurableWrite.syncDirectory(bundle.installDirectory)
        var config = config
        config.removable.removeAll { [mediaID, unattendID, toolsID].contains($0.id) }
        config.install = nil
        return config
    }

    /// Clones `source` into `install/<name>` (copies it across volumes), replacing an older copy.
    private static func place(_ source: URL, as name: String, in bundle: VMBundle) throws -> URL {
        let target = bundle.installDirectory.appendingPathComponent(name)
        let partial = bundle.installDirectory.appendingPathComponent(".\(name).partial-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: partial) }
        do {
            try CloneFile.clone(source, to: partial)
        } catch CloneError.unsupported {
            try FileManager.default.copyItem(at: source, to: partial)
        }
        guard chmod(partial.path, 0o600) == 0 else { throw POSIXError.current() }
        guard rename(partial.path, target.path) == 0 else { throw POSIXError.current() }
        try DurableWrite.syncDirectory(bundle.installDirectory)
        return target
    }

    private static func sameVolume(_ first: URL, _ second: URL) -> Bool {
        let key = URLResourceKey.volumeIdentifierKey
        guard let one = try? first.resourceValues(forKeys: [key]).volumeIdentifier as? NSObject,
            let two = try? second.resourceValues(forKeys: [key]).volumeIdentifier as? NSObject
        else { return false }
        return one.isEqual(two)
    }
}
