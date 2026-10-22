import Foundation

/// `config.json`, schema version 1. Every object keeps unknown keys (see `Extensible`).
public typealias VMConfigV1 = Extensible<VMConfigFields>

public enum GuestOS: String, Codable, Sendable { case macos, linux, windows }
public enum BackendKind: String, Codable, Sendable { case vz, qemu }

public struct VMConfigFields: ExtensibleFields {
    public static let schemaVersion = 1

    public var schemaVersion: Int
    public var id: UUID
    public var name: String
    public var os: GuestOS
    public var backend: BackendKind
    public var cpu: Extensible<CPUConfig>
    public var memory: Extensible<MemoryConfig>
    public var display: Extensible<DisplayConfig>
    public var disks: [Extensible<DiskConfig>]
    public var removable: [Extensible<RemovableConfig>]
    public var platform: Extensible<PlatformConfig>
    public var network: [Extensible<NetworkConfig>]
    public var portForwards: [Extensible<PortForwardConfig>]
    public var shares: [Extensible<ShareConfig>]
    public var audio: Extensible<AudioConfig>
    public var clipboard: Extensible<ClipboardConfig>
    public var vz: Extensible<VZConfig>?
    public var qemu: Extensible<QEMUConfig>?
    public var agent: Extensible<AgentConfig>
    public var mcp: Extensible<MCPConfig>
    public var ui: Extensible<UIConfig>
    public var windows: Extensible<WindowsConfig>?
    /// Where the OS comes from on first start (macOS restore image); removed once installed.
    public var install: Extensible<InstallConfig>?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, id, name, os, backend, cpu, memory, display, disks, removable, platform, network
        case portForwards, shares, audio, clipboard, vz, qemu, agent, mcp, ui, windows, install
    }

    public static let knownKeys = Set(CodingKeys.allCases.map(\.rawValue))
}

public struct CPUConfig: ExtensibleFields {
    public var count: Int

    public init(count: Int) {
        self.count = count
    }

    enum CodingKeys: String, CodingKey, CaseIterable { case count }
    public static let knownKeys = Set(CodingKeys.allCases.map(\.rawValue))
}

public struct MemoryConfig: ExtensibleFields {
    public var mib: Int
    public var balloon: Bool

    public init(mib: Int, balloon: Bool) {
        self.mib = mib
        self.balloon = balloon
    }

    enum CodingKeys: String, CodingKey, CaseIterable { case mib, balloon }
    public static let knownKeys = Set(CodingKeys.allCases.map(\.rawValue))
}

public struct DisplayConfig: ExtensibleFields {
    public enum Scaling: String, Codable, Sendable { case retina, standard }
    public var widthPx: Int
    public var heightPx: Int
    public var ppi: Int
    public var autoResize: Bool
    public var scaling: Scaling

    public init(widthPx: Int, heightPx: Int, ppi: Int, autoResize: Bool, scaling: Scaling) {
        self.widthPx = widthPx
        self.heightPx = heightPx
        self.ppi = ppi
        self.autoResize = autoResize
        self.scaling = scaling
    }

    enum CodingKeys: String, CodingKey, CaseIterable { case widthPx, heightPx, ppi, autoResize, scaling }
    public static let knownKeys = Set(CodingKeys.allCases.map(\.rawValue))
}

public enum StorageBus: String, Codable, Sendable { case virtio, nvme, usb }

public struct DiskConfig: ExtensibleFields {
    public enum Format: String, Codable, Sendable { case raw }
    public var id: String
    /// Path relative to the bundle, e.g. `current/disk.img`.
    public var file: String
    public var format: Format
    public var sizeGiB: Int
    public var bus: StorageBus

    public init(id: String, file: String, format: Format, sizeGiB: Int, bus: StorageBus) {
        self.id = id
        self.file = file
        self.format = format
        self.sizeGiB = sizeGiB
        self.bus = bus
    }

    enum CodingKeys: String, CodingKey, CaseIterable { case id, file, format, sizeGiB, bus }
    public static let knownKeys = Set(CodingKeys.allCases.map(\.rawValue))
}

public struct RemovableConfig: ExtensibleFields {
    public var id: String
    /// Absolute host path of an image (ISO, IMG).
    public var path: String
    public var bus: StorageBus

    public init(id: String, path: String, bus: StorageBus) {
        self.id = id
        self.path = path
        self.bus = bus
    }

    enum CodingKeys: String, CodingKey, CaseIterable { case id, path, bus }
    public static let knownKeys = Set(CodingKeys.allCases.map(\.rawValue))
}

public struct PlatformConfig: ExtensibleFields {
    /// Base64 `VZGenericMachineIdentifier`/`VZMacMachineIdentifier` data. Part of the device set, so the
    /// guest keeps its identity across restarts; a clone gets a new one.
    public var machineIdentifier: String?

    public init(machineIdentifier: String? = nil) {
        self.machineIdentifier = machineIdentifier
    }

    enum CodingKeys: String, CodingKey, CaseIterable { case machineIdentifier }
    public static let knownKeys = Set(CodingKeys.allCases.map(\.rawValue))
}

public struct NetworkConfig: ExtensibleFields {
    public enum Mode: String, Codable, Sendable { case nat, bridged, none }
    public var id: String
    public var mode: Mode
    /// Locally administered unicast MAC, persisted so the guest keeps its leases.
    public var macAddress: String

    public init(id: String, mode: Mode, macAddress: String) {
        self.id = id
        self.mode = mode
        self.macAddress = macAddress
    }

    enum CodingKeys: String, CodingKey, CaseIterable { case id, mode, macAddress }
    public static let knownKeys = Set(CodingKeys.allCases.map(\.rawValue))
}

public enum RuleOrigin: String, Codable, Sendable { case user, agent }

public struct PortForwardConfig: ExtensibleFields {
    public enum Proto: String, Codable, Sendable { case tcp, udp }
    public var id: String
    public var proto: Proto
    public var hostAddress: String
    public var hostPort: Int
    public var guestPort: Int
    public var origin: RuleOrigin

    public init(id: String, proto: Proto, hostAddress: String, hostPort: Int, guestPort: Int, origin: RuleOrigin) {
        self.id = id
        self.proto = proto
        self.hostAddress = hostAddress
        self.hostPort = hostPort
        self.guestPort = guestPort
        self.origin = origin
    }

    enum CodingKeys: String, CodingKey, CaseIterable { case id, proto, hostAddress, hostPort, guestPort, origin }
    public static let knownKeys = Set(CodingKeys.allCases.map(\.rawValue))
}

public struct ShareConfig: ExtensibleFields {
    public var id: String
    public var name: String
    public var hostPath: String
    public var readOnly: Bool

    public init(id: String, name: String, hostPath: String, readOnly: Bool) {
        self.id = id
        self.name = name
        self.hostPath = hostPath
        self.readOnly = readOnly
    }

    enum CodingKeys: String, CodingKey, CaseIterable { case id, name, hostPath, readOnly }
    public static let knownKeys = Set(CodingKeys.allCases.map(\.rawValue))
}

public struct AudioConfig: ExtensibleFields {
    public var output: Bool
    public var input: Bool

    public init(output: Bool, input: Bool) {
        self.output = output
        self.input = input
    }

    enum CodingKeys: String, CodingKey, CaseIterable { case output, input }
    public static let knownKeys = Set(CodingKeys.allCases.map(\.rawValue))
}

public struct ClipboardConfig: ExtensibleFields {
    public enum Mode: String, Codable, Sendable { case both, hostToGuest, guestToHost, off }
    public var mode: Mode
    /// Whether agents (MCP, non-interactive CLI) may read or write the clipboard content.
    public var allowWithAgents: Bool

    public init(mode: Mode, allowWithAgents: Bool) {
        self.mode = mode
        self.allowWithAgents = allowWithAgents
    }

    enum CodingKeys: String, CodingKey, CaseIterable { case mode, allowWithAgents }
    public static let knownKeys = Set(CodingKeys.allCases.map(\.rawValue))
}

public struct VZConfig: ExtensibleFields {
    public var rosetta: Bool
    public var nestedVirtualization: Bool

    public init(rosetta: Bool, nestedVirtualization: Bool) {
        self.rosetta = rosetta
        self.nestedVirtualization = nestedVirtualization
    }

    enum CodingKeys: String, CodingKey, CaseIterable { case rosetta, nestedVirtualization }
    public static let knownKeys = Set(CodingKeys.allCases.map(\.rawValue))
}

public struct QEMUConfig: ExtensibleFields {
    public enum GPU: String, Codable, Sendable { case ramfb, virtio }
    public var tpm: Bool
    public var secureBoot: Bool
    public var gpu: GPU
    public var storageBus: StorageBus
    public var smbiosUUID: UUID

    public init(tpm: Bool, secureBoot: Bool, gpu: GPU, storageBus: StorageBus, smbiosUUID: UUID) {
        self.tpm = tpm
        self.secureBoot = secureBoot
        self.gpu = gpu
        self.storageBus = storageBus
        self.smbiosUUID = smbiosUUID
    }

    enum CodingKeys: String, CodingKey, CaseIterable { case tpm, secureBoot, gpu, storageBus, smbiosUUID }
    public static let knownKeys = Set(CodingKeys.allCases.map(\.rawValue))
}

public struct AgentConfig: ExtensibleFields {
    public enum Transport: String, Codable, Sendable { case auto, vsock, virtioSerial, tcp }
    public var transport: Transport

    public init(transport: Transport) {
        self.transport = transport
    }

    enum CodingKeys: String, CodingKey, CaseIterable { case transport }
    public static let knownKeys = Set(CodingKeys.allCases.map(\.rawValue))
}

public struct MCPConfig: ExtensibleFields {
    public var policy: PolicyLevel
    public var confirmExec: Bool
    public var autoSnapshot: Bool
    public var auditTypedText: Bool
    /// Let agents sign the guest in with the password kept for it (`GuestCredentials`); absent is off.
    public var signIn: Bool?
    /// HMAC over the VM id and these settings, written only by the app. Missing or wrong → policy `off`.
    public var tag: String?

    public init(
        policy: PolicyLevel, confirmExec: Bool, autoSnapshot: Bool, auditTypedText: Bool, signIn: Bool? = nil, tag: String? = nil
    ) {
        self.policy = policy
        self.confirmExec = confirmExec
        self.autoSnapshot = autoSnapshot
        self.auditTypedText = auditTypedText
        self.signIn = signIn
        self.tag = tag
    }

    enum CodingKeys: String, CodingKey, CaseIterable { case policy, confirmExec, autoSnapshot, auditTypedText, signIn, tag }
    public static let knownKeys = Set(CodingKeys.allCases.map(\.rawValue))
}

public struct UIConfig: ExtensibleFields {
    public enum CloseAction: String, Codable, Sendable { case keepRunning, suspend, stop }
    public var closeAction: CloseAction
    public var icon: String?

    public init(closeAction: CloseAction, icon: String? = nil) {
        self.closeAction = closeAction
        self.icon = icon
    }

    enum CodingKeys: String, CodingKey, CaseIterable { case closeAction, icon }
    public static let knownKeys = Set(CodingKeys.allCases.map(\.rawValue))
}

/// A guest still being installed; removed from the config once the install is done.
public struct InstallConfig: ExtensibleFields {
    /// macOS: absolute path of the restore image (`.ipsw`) to install from on first start.
    public var restoreImage: String?
    /// Linux: id of the `removable` entry holding the installer ISO, detached after the installer's reboot.
    public var media: String?

    public init(restoreImage: String? = nil, media: String? = nil) {
        self.restoreImage = restoreImage
        self.media = media
    }

    enum CodingKeys: String, CodingKey, CaseIterable { case restoreImage, media }
    public static let knownKeys = Set(CodingKeys.allCases.map(\.rawValue))
}

public struct WindowsConfig: ExtensibleFields {
    public var eulaAcceptedAt: Date?

    public init(eulaAcceptedAt: Date? = nil) {
        self.eulaAcceptedAt = eulaAcceptedAt
    }

    enum CodingKeys: String, CodingKey, CaseIterable { case eulaAcceptedAt }
    public static let knownKeys = Set(CodingKeys.allCases.map(\.rawValue))
}

extension DisplayConfig.Scaling {
    /// The guest resolution for a window content size (points): pixels with retina scaling, points with standard
    /// scaling (the view then draws each guest pixel over a point, so text is its usual size); even (some drivers
    /// want it) and at least `minimum`.
    public func guestResolution(forContent size: CGSize, backingScale: CGFloat, minimum: CGSize) -> CGSize {
        let factor = self == .retina ? max(backingScale, 1) : 1
        func even(_ value: CGFloat, atLeast low: CGFloat) -> CGFloat { max((value * factor / 2).rounded(.down) * 2, low) }
        return CGSize(width: even(size.width, atLeast: minimum.width), height: even(size.height, atLeast: minimum.height))
    }
}

extension VMConfigFields {
    /// A new VM's config with VMPane's defaults for `os`.
    public static func new(id: UUID = UUID(), name: String, os: GuestOS, diskGiB: Int = 64, macAddress: String) -> VMConfigFields {
        let backend: BackendKind = os == .windows ? .qemu : .vz
        return VMConfigFields(
            schemaVersion: schemaVersion, id: id, name: name, os: os, backend: backend,
            cpu: Extensible(CPUConfig(count: 4)),
            memory: Extensible(MemoryConfig(mib: os == .windows ? 8192 : 4096, balloon: true)),
            // Linux: one guest pixel per point, so a text console or installer is readable (it cannot scale itself).
            display: Extensible(
                DisplayConfig(widthPx: 1920, heightPx: 1200, ppi: 144, autoResize: true, scaling: os == .linux ? .standard : .retina)),
            disks: [
                Extensible(
                    DiskConfig(
                        id: "root", file: "current/disk.img", format: .raw, sizeGiB: diskGiB,
                        bus: os == .windows ? .nvme : .virtio))
            ],
            removable: [],
            platform: Extensible(PlatformConfig(machineIdentifier: nil)),
            network: [Extensible(NetworkConfig(id: "nic0", mode: .nat, macAddress: macAddress))],
            portForwards: [], shares: [],
            audio: Extensible(AudioConfig(output: true, input: false)),
            clipboard: Extensible(ClipboardConfig(mode: .both, allowWithAgents: false)),
            vz: backend == .vz ? Extensible(VZConfig(rosetta: os == .linux, nestedVirtualization: false)) : nil,
            qemu: backend == .qemu
                ? Extensible(QEMUConfig(tpm: true, secureBoot: true, gpu: .ramfb, storageBus: .nvme, smbiosUUID: UUID())) : nil,
            agent: Extensible(AgentConfig(transport: .auto)),
            mcp: Extensible(MCPConfig(policy: .off, confirmExec: true, autoSnapshot: true, auditTypedText: false, tag: nil)),
            ui: Extensible(UIConfig(closeAction: .keepRunning, icon: nil)),
            windows: os == .windows ? Extensible(WindowsConfig(eulaAcceptedAt: nil)) : nil,
            install: nil)
    }
}
