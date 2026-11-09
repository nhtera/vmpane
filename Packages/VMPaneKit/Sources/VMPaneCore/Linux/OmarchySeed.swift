import Foundation

/// The `cidata` drive Omarchy's ISO installs itself from with no keyboard (its autoinstall): archinstall's
/// `user_configuration.json` (the disk's layout, the host name, Limine for arm64, Omarchy's packages) and
/// `user_credentials.json` (the user, an administrator, with the password only as a `$6$` hash), the flag that the disk
/// is not encrypted (a VM's start would otherwise ask for the passphrase every time) and, with a key,
/// `authorized_keys` (the installer then enables sshd, which Omarchy keeps off otherwise). The volume is labelled
/// `cidata`, as cloud-init's; the installer falls back to its configurator when a required file is missing.
public struct OmarchySeed: Sendable, Equatable {
    public typealias Problem = CloudInitSeed.Problem

    public var hostName: String
    public var userName: String
    public var passwordHash: String
    public var sshKey: String?
    /// The VM's disk, in bytes: the layout covers the whole of it.
    public var diskBytes: UInt64
    /// The installed system's time zone (a tz database name, as the Mac's).
    public var timeZone: String

    /// Omarchy's layout: an ESP of 2 GiB (its boot entries, kernels and snapshots' kernels), the rest btrfs.
    public static let espBytes: UInt64 = 2 << 30
    static let mebibyte: UInt64 = 1 << 20
    /// The disk must hold the ESP and a root with room for the system (4.2 GB installed).
    public static let minimumDiskBytes: UInt64 = 8 << 30

    public init(
        hostName: String, userName: String, passwordHash: String, sshKey: String? = nil, diskBytes: UInt64,
        timeZone: String = TimeZone.current.identifier
    ) throws {
        guard CloudInitSeed.isUserName(userName) else { throw Problem.userName }
        guard !hostName.isEmpty, hostName.count <= 63, hostName.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") })
        else { throw Problem.hostName }
        let key = sshKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let key, !key.isEmpty, !CloudInitSeed.isSSHKey(key) { throw Problem.sshKey }
        guard diskBytes >= Self.minimumDiskBytes else { throw Problem.diskTooSmall }
        self.hostName = hostName
        self.userName = userName
        self.passwordHash = passwordHash
        self.sshKey = key.flatMap { $0.isEmpty ? nil : $0 }
        self.diskBytes = diskBytes
        self.timeZone = TimeZone(identifier: timeZone) == nil ? "UTC" : timeZone
    }

    /// archinstall's partition identities, which the configurator makes up too: the installer refers to the partitions
    /// by them (encryption, mounts), not by path.
    static let espID = "ea21d3f2-82bb-49cc-ab5d-6f81ae94e18d"
    static let rootID = "8c2c2b92-1070-455d-b76a-56263bab24aa"

    /// Where the two partitions go, in bytes.
    struct Layout: Equatable {
        var espStart: UInt64
        var espSize: UInt64
        var rootStart: UInt64
        var rootSize: UInt64
    }

    /// The layout: the ESP from 1 MiB, the root after it to 1 MiB before the end (GPT's backup table).
    var layout: Layout {
        let rootStart = Self.mebibyte + Self.espBytes
        return Layout(
            espStart: Self.mebibyte, espSize: Self.espBytes, rootStart: rootStart, rootSize: diskBytes - rootStart - Self.mebibyte)
    }

    /// `user_configuration.json`: what the configurator writes for a full-disk install on arm64, for the VM's disk.
    public var userConfiguration: String {
        let layout = layout
        func size(_ bytes: UInt64) -> [String: Any] {
            ["sector_size": ["unit": "B", "value": 512], "unit": "B", "value": bytes]
        }
        let esp: [String: Any] = [
            "btrfs": [], "dev_path": NSNull(), "flags": ["boot", "esp"], "fs_type": "fat32", "mount_options": [],
            "mountpoint": "/boot", "obj_id": Self.espID, "size": size(layout.espSize), "start": size(layout.espStart),
            "status": "create", "type": "primary",
        ]
        let root: [String: Any] = [
            "btrfs": [
                ["mountpoint": "/", "name": "@"], ["mountpoint": "/home", "name": "@home"],
                ["mountpoint": "/var/log", "name": "@log"], ["mountpoint": "/var/cache/pacman/pkg", "name": "@pkg"],
            ],
            "dev_path": NSNull(), "flags": [], "fs_type": "btrfs", "mount_options": ["compress=zstd"], "mountpoint": NSNull(),
            "obj_id": Self.rootID, "size": size(layout.rootSize), "start": size(layout.rootStart), "status": "create",
            "type": "primary",
        ]
        let configuration: [String: Any] = [
            "app_config": NSNull(),
            "archinstall-language": "English",
            "auth_config": [:],
            "audio_config": ["audio": "pipewire"],
            "bootloader_config": ["bootloader": "Limine", "uki": false, "removable": false],
            "custom_commands": [],
            "omarchy_install": [
                "mode": "full_disk", "defer_provisioning": false, "target_mount": "/mnt",
                "boot": ["esp_mount": "/boot", "esp_path": "/EFI/limine", "efi_binary": "limine_aa64.efi", "enable_fallback": true],
                "storage": ["kernel": "linux-omarchy"],
            ],
            "disk_config": [
                "config_type": "default_layout",
                // The VM's disk is its first virtio block device.
                "device_modifications": [["device": "/dev/vda", "partitions": [esp, root], "wipe": true]],
            ],
            "hostname": hostName,
            "kernels": ["linux-omarchy"],
            "network_config": ["type": "iso"],
            "ntp": true,
            "parallel_downloads": 8,
            "script": NSNull(),
            "services": [],
            "swap": true,
            "timezone": timeZone,
            "locale_config": ["kb_layout": "us", "sys_enc": "UTF-8", "sys_lang": "en_US.UTF-8"],
            // Omarchy's own mirror of Arch Linux ARM for the stable channel: the installer takes its packages from
            // the ISO; the installed system updates from here.
            "mirror_config": [
                "custom_repositories": [], "custom_servers": [["url": "https://arm-stable-mirror.omarchy.org/$arch/$repo"]],
                "mirror_regions": [:], "optional_repositories": [],
            ],
            "packages": ["base-devel", "git", "omarchy-keyring", "omarchy-settings", "omarchy"],
            "profile_config": ["gfx_driver": NSNull(), "greeter": NSNull(), "profile": [:]],
            "version": "3.0.9",
        ]
        return Self.json(configuration)
    }

    /// `user_credentials.json`: the user, an administrator, and root with the same hash (as the configurator writes).
    public var userCredentials: String {
        Self.json([
            "root_enc_password": passwordHash,
            "users": [["enc_password": passwordHash, "groups": [], "sudo": true, "username": userName]],
        ])
    }

    static func json(_ object: [String: Any]) -> String {
        // Sorted keys: the same seed writes the same bytes (tests compare them).
        let options: JSONSerialization.WritingOptions = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = (try? JSONSerialization.data(withJSONObject: object, options: options)) ?? Data()
        return (String(bytes: data, encoding: .utf8) ?? "") + "\n"
    }

    /// The seed's files in `directory` (0600 in a 0700 folder) and its ISO beside it (`<directory>.iso`, 0600).
    public func write(to directory: URL) throws -> URL {
        let fm = FileManager.default
        try? fm.removeItem(at: directory)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try CloudInitSeed.writePrivate(userConfiguration, to: directory.appendingPathComponent("user_configuration.json"))
        try CloudInitSeed.writePrivate(userCredentials, to: directory.appendingPathComponent("user_credentials.json"))
        try CloudInitSeed.writePrivate("false\n", to: directory.appendingPathComponent("user_encrypt_installation.txt"))
        if let sshKey { try CloudInitSeed.writePrivate(sshKey + "\n", to: directory.appendingPathComponent("authorized_keys")) }
        return try CloudInitSeed.makeISO(directory)
    }
}
