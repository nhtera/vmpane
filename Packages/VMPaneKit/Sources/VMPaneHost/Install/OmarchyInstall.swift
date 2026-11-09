import Foundation
import VMPaneCore

/// Omarchy from its arm64 ISO with no clicks: the ISO boots as install media (`LinuxInstall.prepare`), and a `cidata`
/// seed beside it (`OmarchySeed`: the account from the wizard, the disk's layout, the host name) makes the installer run
/// by itself, in a few minutes; the VM then restarts in place into Omarchy's lock screen. The seed is the cloud images'
/// (`install/cidata`, device `cidata`, `install.cloudInit`), so the helper removes it the same way: once the boot
/// loader is installed (nothing in the installed system reads it) or the guest tools connect, its data goes; its
/// device at the next stop, with the ISO. Omarchy enables SSH only with a key, so the forward comes with one.
public enum OmarchyInstall {
    public enum Failure: Error, Equatable, CustomStringConvertible {
        case notAutoinstall
        case noMedia

        public var description: String {
            switch self {
            case .notAutoinstall: "this catalog image does not install itself"
            case .noMedia: "the VM has no install media to seed"
            }
        }
    }

    /// `config` (its ISO attached by `LinuxInstall.prepare`) with the seed for `account` attached. Holds the bundle's
    /// lock.
    public static func apply(
        _ config: VMConfigV1, image: ImageCatalog.Image, account: CloudImageInstall.Account, holding lock: BundleLock
    ) throws -> VMConfigV1 {
        guard image.isAutoinstallISO else { throw Failure.notAutoinstall }
        guard config.install?.media != nil, let disk = config.disks.first else { throw Failure.noMedia }
        var config = config
        let seed = try OmarchySeed(
            hostName: CloudImageInstall.hostName(config.name), userName: account.userName,
            passwordHash: SHA512Crypt.hash(account.password), sshKey: account.sshKey, diskBytes: UInt64(disk.sizeGiB) << 30)
        try FileManager.default.createDirectory(
            at: lock.bundle.installDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let iso = try seed.write(to: CloudImageInstall.seedDirectory(in: lock.bundle))
        config.removable.removeAll { $0.id == CloudImageInstall.seedID }
        config.removable.append(Extensible(RemovableConfig(id: CloudImageInstall.seedID, path: iso.path, bus: .virtio)))
        config.install?.cloudInit = CloudImageInstall.seedID
        if seed.sshKey != nil, !config.portForwards.contains(where: { $0.guestPort == 22 }), let port = LoopbackPort.free() {
            config.portForwards.append(
                Extensible(
                    PortForwardConfig(id: "ssh", proto: .tcp, hostAddress: "127.0.0.1", hostPort: port, guestPort: 22, origin: .user)))
        }
        return config
    }
}
