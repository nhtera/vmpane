import Darwin
import Foundation
import VMPaneCore

public enum QEMUConfigError: Error, Equatable, Sendable, CustomStringConvertible {
    case unsupportedGuest(GuestOS)
    /// A QEMU VM's config has no `qemu` section.
    case missingQEMUSettings
    case invalidMACAddress(String)
    case bridgedNetworkingUnavailable
    /// A port forward that is not a literal IPv4 host address, ports 1…65535.
    case invalidPortForward(id: String)
    /// A Unix socket path longer than `sun_path` allows.
    case socketPathTooLong(String)
    case missingFile(String)
    /// The QEMU sandbox reads only the VM's bundle and the QEMU runtime: media elsewhere must be copied in first.
    case mediaOutsideBundle(String)
    /// Secure Boot off needs a variable template without keys, which this build does not ship.
    case secureBootRequired

    public var description: String {
        switch self {
        case .unsupportedGuest(let os): "QEMU cannot run \(os.rawValue) guests"
        case .missingQEMUSettings: "the VM's configuration has no QEMU settings"
        case .invalidMACAddress(let mac): "invalid MAC address \(mac)"
        case .bridgedNetworkingUnavailable: "bridged networking is not available for Windows VMs"
        case .invalidPortForward(let id): "port forward \(id) needs a literal IPv4 host address and ports 1–65535"
        case .socketPathTooLong(let path): "socket path too long: \(path)"
        case .missingFile(let path): "missing file \(path)"
        case .mediaOutsideBundle(let path): "\(path) is outside the VM: Windows VMs use media inside their bundle"
        case .secureBootRequired: "Windows VMs run with Secure Boot on"
        }
    }
}

/// Maps a VM's config to `qemu-system-aarch64` arguments. Pure: no file is touched, so every config
/// variant is golden-tested. Values inside QEMU option strings are escaped (`,` → `,,`), and nothing from
/// the config other than validated numbers, MACs and IPv4 literals reaches an option string unescaped.
public enum QEMUArgvBuilder {
    /// Longest Unix socket path QEMU and swtpm can bind (`sun_path` is 104 bytes with the NUL).
    public static let maxSocketPathLength = 103

    /// `incoming`: start paused, waiting for `migrate-incoming` (restoring saved RAM state).
    public static func arguments(
        _ config: VMConfigV1, layout: QEMULayout, incoming: Bool = false,
        fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) throws -> [String] {
        guard let profile = QEMUDeviceProfile.for(config.os) else { throw QEMUConfigError.unsupportedGuest(config.os) }
        guard let qemu = config.qemu else { throw QEMUConfigError.missingQEMUSettings }
        guard qemu.secureBoot else { throw QEMUConfigError.secureBootRequired }
        for socket in layout.sockets where socket.path.utf8.count > maxSocketPathLength {
            throw QEMUConfigError.socketPathTooLong(socket.path)
        }

        var args: [String] = [
            "-nodefaults", "-no-user-config",
            // Never the user's VM name: QEMU shows it in its process title and the SPICE server name.
            "-name", "guest=vmpane-\(ShortID(config.id))",
            "-uuid", qemu.smbiosUUID.uuidString.lowercased(),
            "-machine", profile.machine,
            "-accel", "hvf", "-cpu", "host",
            "-smp", String(config.cpu.count), "-m", "\(config.memory.mib)M",
            "-L", path(layout.qemuData),
            "-display", "none",
            // A guest power-off pauses QEMU instead of exiting it; the backend disconnects the display, then quits.
            "-no-shutdown",
            "-rtc", profile.rtc,
            "-drive", "if=pflash,format=raw,readonly=on,file=\(path(layout.firmwareCode))",
            "-drive", "if=pflash,format=raw,file=\(path(layout.efiVariables))",
        ]

        if qemu.tpm {
            args += [
                "-chardev", "socket,id=chrtpm,path=\(path(layout.tpmSocket))",
                "-tpmdev", "emulator,id=tpm0,chardev=chrtpm",
                "-device", profile.tpmDevice,
            ]
        }

        // The USB controller first: USB storage attaches to it.
        for device in profile.inputDevices { args += ["-device", device] }
        args += try storage(config, layout: layout, fileExists: fileExists)
        args += ["-device", qemu.gpu == .virtio ? "virtio-gpu-pci" : "ramfb"]
        args += try network(config)

        // SPICE: display, input, clipboard (vdagent) over a Unix socket in the 0700 run directory, so the
        // socket's permissions are the access control. No compression or video streams on a local socket.
        args += [
            "-spice",
            "unix=on,addr=\(path(layout.spiceSocket)),disable-ticketing=on,image-compression=off,streaming-video=off",
            "-device", "virtio-serial-pci,id=vser",
            "-chardev", "spicevmc,id=vdagent,name=vdagent",
            "-device", "virtserialport,bus=vser.0,chardev=vdagent,name=com.redhat.spice.0",
            "-chardev", "socket,id=agent,path=\(path(layout.agentSocket)),server=on,wait=off",
            "-device", "virtserialport,bus=vser.0,chardev=agent,name=app.vmpane.agent.0",
        ]

        if config.audio.output {
            args += ["-audiodev", "coreaudio,id=snd0"]
            for device in profile.audioDevices { args += ["-device", device] }
        }
        args += ["-device", "virtio-rng-pci"]
        if config.memory.balloon { args += ["-device", "virtio-balloon-pci"] }
        args += ["-device", "pvpanic-pci"]

        args += ["-qmp", "unix:\(path(layout.qmpSocket)),server=on,wait=off"]
        // Restoring: paused (-S) until the state is loaded and the backend continues it.
        if incoming { args += ["-S", "-incoming", "defer"] }
        return args
    }

    /// Disks (each gets a boot index: EDK2 drops devices without one from BootOrder), then removable media.
    /// The install medium boots first. Node names are positional, so config ids never reach QEMU.
    private static func storage(_ config: VMConfigV1, layout: QEMULayout, fileExists: (URL) -> Bool) throws -> [String] {
        var args: [String] = []
        let installMedia = config.install?.media
        var bootIndex = config.removable.contains { $0.id == installMedia } ? 1 : 0
        for (index, disk) in config.disks.enumerated() {
            let url = try layout.bundleFile(disk.file)
            guard fileExists(url) else { throw QEMUConfigError.missingFile(disk.file) }
            let node = "disk\(index)"
            args += ["-blockdev", "node-name=\(node),driver=raw,discard=unmap,file.driver=file,file.filename=\(path(url))"]
            args += ["-device", device(for: disk.bus, node: node, serial: "vmpane-\(index)", bootIndex: bootIndex)]
            bootIndex += 1
        }
        for (index, media) in config.removable.enumerated() {
            let url = try layout.mediaFile(media.path)
            guard fileExists(url) else { throw QEMUConfigError.missingFile(media.path) }
            // Device ids let QMP find and eject the medium (the install ISO after Setup's first reboot). USB media
            // are ISOs: a CD-ROM (scsi-cd under usb-storage, as in S1), which needs the legacy -drive syntax.
            let node = "media\(index)"
            if media.bus == .usb {
                args += ["-drive", "if=none,id=\(node),media=cdrom,readonly=on,format=raw,file=\(path(url))"]
            } else {
                args += ["-blockdev", "node-name=\(node),driver=raw,read-only=on,file.driver=file,file.filename=\(path(url))"]
            }
            let boot = media.id == installMedia ? 0 : nil
            args += ["-device", device(for: media.bus, node: node, serial: nil, bootIndex: boot, removable: true) + ",id=\(node)-dev"]
        }
        return args
    }

    private static func device(for bus: StorageBus, node: String, serial: String?, bootIndex: Int?, removable: Bool = false) -> String {
        var options: [String]
        switch bus {
        case .nvme: options = ["nvme", "drive=\(node)"]
        case .virtio: options = ["virtio-blk-pci", "drive=\(node)"]
        case .usb: options = ["usb-storage", "bus=xhci.0", "drive=\(node)"] + (removable ? ["removable=on"] : [])
        }
        if let serial { options.append("serial=\(serial)") }
        if let bootIndex { options.append("bootindex=\(bootIndex)") }
        return options.joined(separator: ",")
    }

    /// slirp NAT per NIC (`hostfwd` rules on the first one). No vmnet: bridged is unavailable. An install gets no
    /// NIC at all, whatever the config says: without network Windows Setup offers the local account (S1).
    private static func network(_ config: VMConfigV1) throws -> [String] {
        guard config.install == nil else { return [] }
        var args: [String] = []
        let nics = try config.network.filter { nic in
            switch nic.mode {
            case .none: return false
            case .bridged: throw QEMUConfigError.bridgedNetworkingUnavailable
            case .nat: return true
            }
        }
        for (index, nic) in nics.enumerated() {
            guard isValidMAC(nic.macAddress) else { throw QEMUConfigError.invalidMACAddress(nic.macAddress) }
            var netdev = "user,id=net\(index),ipv6=off"
            if index == 0 {
                for rule in config.portForwards { netdev += ",hostfwd=" + (try hostForward(rule)) }
            }
            args += ["-netdev", netdev, "-device", "virtio-net-pci,netdev=net\(index),mac=\(nic.macAddress.lowercased())"]
        }
        return args
    }

    /// `tcp:127.0.0.1:8080-:80`, built only from validated parts (Red Team #13).
    static func hostForward(_ rule: Extensible<PortForwardConfig>) throws -> String {
        guard isIPv4Literal(rule.hostAddress), (1...65535).contains(rule.hostPort), (1...65535).contains(rule.guestPort) else {
            throw QEMUConfigError.invalidPortForward(id: rule.id)
        }
        return "\(rule.proto.rawValue):\(rule.hostAddress):\(rule.hostPort)-:\(rule.guestPort)"
    }

    static func isIPv4Literal(_ text: String) -> Bool {
        var address = in_addr()
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }
            && inet_pton(AF_INET, text, &address) == 1
    }

    static func isValidMAC(_ mac: String) -> Bool {
        let parts = mac.split(separator: ":", omittingEmptySubsequences: false)
        return parts.count == 6 && parts.allSatisfy { $0.count == 2 && $0.allSatisfy(\.isHexDigit) && $0.allSatisfy(\.isASCII) }
    }

    /// A value inside a QEMU option string: `,` separates options, so it is doubled.
    static func escape(_ value: String) -> String { value.replacingOccurrences(of: ",", with: ",,") }

    private static func path(_ url: URL) -> String { escape(url.path) }
}
