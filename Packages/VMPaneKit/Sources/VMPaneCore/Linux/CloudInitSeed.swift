import Foundation

/// The cloud-init NoCloud seed a cloud image's first boot reads (volume `cidata`): the user (its password only as a
/// `$6$` hash), an optional SSH key, the host name, VMPane's guest tools from the `vmpane-tools` share, and for Desktop
/// the GNOME packages with automatic login. `instance-id` is new for every VM (a clone gets its own), so cloud-init
/// runs once per machine. What it carries goes once the guest tools run: the seed from the bundle (the helper), the
/// copies cloud-init keeps in the guest (`runcmd`).
public struct CloudInitSeed: Sendable, Equatable {
    public enum Distro: String, Sendable, Codable, CaseIterable { case ubuntu, debian, fedora }

    public enum Problem: Error, Equatable, CustomStringConvertible {
        case userName, hostName, sshKey
        case isoFailed(String)

        public var description: String {
            switch self {
            case .userName: "a Linux user name is 1 to 32 lowercase letters, digits, - and _, starting with a letter"
            case .hostName: "the host name is letters, digits and hyphens"
            case .sshKey: "the SSH key is one line, as in ~/.ssh/id_ed25519.pub"
            case .isoFailed(let message): "the cloud-init seed could not be written: \(message)"
            }
        }
    }

    public var distro: Distro
    public var hostName: String
    public var userName: String
    public var passwordHash: String
    public var sshKey: String?
    public var desktop: Bool
    public var instanceID: String

    public init(
        distro: Distro, hostName: String, userName: String, passwordHash: String, sshKey: String? = nil, desktop: Bool = false,
        instanceID: String = UUID().uuidString.lowercased()
    ) throws {
        guard Self.isUserName(userName) else { throw Problem.userName }
        guard !hostName.isEmpty, hostName.count <= 63, hostName.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") })
        else { throw Problem.hostName }
        let key = sshKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let key, !key.isEmpty, !Self.isSSHKey(key) { throw Problem.sshKey }
        self.distro = distro
        self.hostName = hostName
        self.userName = userName
        self.passwordHash = passwordHash
        self.sshKey = key.flatMap { $0.isEmpty ? nil : $0 }
        self.desktop = desktop
        self.instanceID = instanceID
    }

    /// Lowercase letters, digits, `-` and `_`, starting with a letter, and none the images have already (a group or
    /// a system user: the account would not be made).
    public static func isUserName(_ name: String) -> Bool {
        guard let first = name.first, first.isASCII, first.isLowercase, name.count <= 32, !reservedNames.contains(name),
            !name.hasPrefix("systemd-")
        else { return false }
        return name.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    /// Users and groups of the Ubuntu, Debian and Fedora cloud images.
    public static let reservedNames: Set<String> = [
        "root", "daemon", "bin", "sys", "sync", "games", "man", "lp", "mail", "news", "uucp", "proxy", "www-data", "backup",
        "list", "irc", "gnats", "nobody", "nogroup", "sshd", "messagebus", "syslog", "uuidd", "tcpdump", "tss", "polkitd",
        "landscape", "fwupd-refresh", "dnsmasq", "usbmux", "rtkit", "pulse", "colord", "gdm", "geoclue", "avahi", "saned",
        "adm", "tty", "disk", "kmem", "dialout", "fax", "voice", "cdrom", "floppy", "tape", "sudo", "audio", "dip", "video",
        "plugdev", "staff", "users", "shadow", "utmp", "operator", "src", "sasl", "input", "kvm", "render", "crontab",
        "netdev", "lxd", "docker", "wheel", "ftp", "halt", "shutdown", "chrony", "dbus", "systemd", "admin",
    ]

    /// One public key line: printable ASCII only (anything else could make cloud-init drop the whole seed).
    public static func isSSHKey(_ key: String) -> Bool {
        let prefixes = ["ssh-", "ecdsa-", "sk-ssh-", "sk-ecdsa-"]
        return prefixes.contains(where: key.hasPrefix) && key.unicodeScalars.allSatisfy { (0x20...0x7E).contains($0.value) }
    }

    /// Every value quoted: YAML 1.1 would read "2026" as a number and "no" as false.
    public var metaData: String { "instance-id: \(Self.quoted(instanceID))\nlocal-hostname: \(Self.quoted(hostName))\n" }

    /// The `#cloud-config` user-data (YAML; the hash and key are quoted strings).
    public var userData: String {
        var lines = [
            "#cloud-config", "hostname: \(Self.quoted(hostName))", "users:", "  - name: \(Self.quoted(userName))",
            "    gecos: \(Self.quoted(userName))",
            "    groups: [\(distro == .fedora ? "wheel" : "sudo")]", "    shell: /bin/bash", "    lock_passwd: false",
            "    passwd: \(Self.quoted(passwordHash))",
        ]
        if let sshKey { lines += ["    ssh_authorized_keys:", "      - \(Self.quoted(sshKey))"] }
        lines += ["ssh_pwauth: \(sshKey == nil)", "growpart:", "  mode: auto", "  devices: [\"/\"]", "resize_rootfs: true"]
        if desktop {
            lines += ["package_update: true", "packages:"] + Self.desktopPackages[distro, default: []].map { "  - \($0)" }
        }
        lines += [
            "runcmd:",
            // VMPane's guest tools, from the share VMPane gives every Linux VM (after the packages: the session helper
            // then starts with the desktop).
            "  - [sh, -c, \"mkdir -p /mnt/vmpane-tools && (mountpoint -q /mnt/vmpane-tools || mount -t virtiofs vmpane-tools "
                + "/mnt/vmpane-tools) && /mnt/vmpane-tools/install.sh\"]",
        ]
        if desktop {
            // GDM's own settings file: Debian builds gdm3 to read daemon.conf.
            let gdm = [.fedora: "/etc/gdm/custom.conf", .debian: "/etc/gdm3/daemon.conf"][distro] ?? "/etc/gdm3/custom.conf"
            lines += [
                "  - [sh, -c, \"mkdir -p \((gdm as NSString).deletingLastPathComponent) && printf "
                    + "'[daemon]\\\\nAutomaticLoginEnable=True\\\\nAutomaticLogin=\(userName)\\\\n' > \(gdm)\"]",
                "  - [systemctl, set-default, graphical.target]",
            ]
        }
        // What cloud-init keeps of the seed in the guest: the password's hash, the key.
        lines += [
            "  - [sh, -c, \"rm -f /var/lib/cloud/instances/*/user-data.txt* /var/lib/cloud/instances/*/cloud-config.txt\"]"
        ]
        if desktop { lines += ["power_state:", "  mode: reboot", "  condition: true"] }
        return lines.joined(separator: "\n") + "\n"
    }

    static let desktopPackages: [Distro: [String]] = [
        .ubuntu: ["ubuntu-desktop-minimal"], .debian: ["task-gnome-desktop"], .fedora: ["@workstation-product-environment"],
    ]

    /// A YAML double-quoted string.
    static func quoted(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case _ where scalar.value < 0x20 || scalar.value == 0x7F: out += String(format: "\\x%02X", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }

    // MARK: - Files

    /// The seed's files in `directory` (`user-data`, `meta-data`, 0600 in a 0700 folder) and its ISO beside it
    /// (`<directory>.iso`, 0600), which the VM boots with.
    public func write(to directory: URL) throws -> URL {
        let fm = FileManager.default
        try? fm.removeItem(at: directory)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try Self.writePrivate(userData, to: directory.appendingPathComponent("user-data"))
        try Self.writePrivate(metaData, to: directory.appendingPathComponent("meta-data"))
        return try Self.makeISO(directory)
    }

    /// The seed in `directory` for a new machine (a clone): a fresh `instance-id`, the ISO made again.
    public static func reissue(_ directory: URL) throws -> URL {
        let file = directory.appendingPathComponent("meta-data")
        let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n").map {
            $0.hasPrefix("instance-id:") ? "instance-id: \(quoted(UUID().uuidString.lowercased()))" : String($0)
        }
        try writePrivate(lines.joined(separator: "\n") + "\n", to: file)
        return try makeISO(directory)
    }

    /// Removes the seed's files and ISO.
    public static func remove(_ directory: URL) {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.removeItem(at: iso(of: directory))
    }

    public static func iso(of directory: URL) -> URL {
        directory.deletingLastPathComponent().appendingPathComponent(directory.lastPathComponent + ".iso", isDirectory: false)
    }

    private static func writePrivate(_ text: String, to url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        guard FileManager.default.createFile(atPath: url.path, contents: Data(text.utf8), attributes: [.posixPermissions: 0o600])
        else { throw Problem.isoFailed("cannot write \(url.lastPathComponent)") }
    }

    /// Built beside it and renamed into place (0600 first), so a VM never sees half an ISO.
    private static func makeISO(_ directory: URL) throws -> URL {
        let iso = iso(of: directory)
        let partial = directory.deletingLastPathComponent().appendingPathComponent(".\(iso.lastPathComponent).\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: partial) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = [
            "makehybrid", "-quiet", "-iso", "-joliet", "-default-volume-name", "cidata", "-o", partial.path, directory.path,
        ]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(bytes: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw Problem.isoFailed(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        // hdiutil adds ".iso" to a name without it.
        let made = FileManager.default.fileExists(atPath: partial.path) ? partial : partial.appendingPathExtension("iso")
        defer { try? FileManager.default.removeItem(at: made) }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: made.path)
        guard rename(made.path, iso.path) == 0 else { throw Problem.isoFailed(String(cString: strerror(errno))) }
        return iso
    }
}
