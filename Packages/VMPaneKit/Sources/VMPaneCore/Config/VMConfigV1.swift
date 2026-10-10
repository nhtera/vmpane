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

    enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, id, name, os, backend, cpu, memory, display, disks, removable, platform, network
        case portForwards, shares, audio, clipboard, vz, qemu, agent, mcp, ui, windows
    }

    public static let knownKeys = Set(CodingKeys.allCases.map(\.rawValue))
}

public struct CPUConfig: ExtensibleFields {
    public var count: Int
    enum CodingKeys: String, CodingKey, CaseIterable { case count }
    public static let knownKeys = Set(CodingKeys.allCases.map(\.rawValue))
}

public struct MemoryConfig: ExtensibleFields {
    public var mib: Int
    public var balloon: Bool
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
    enum CodingKeys: String, CodingKey, CaseIterable { case id, file, format, sizeGiB, bus }
    public static let knownKeys = Set(CodingKeys.allCases.map(\.rawValue))
}

public struct RemovableConfig: ExtensibleFields {
    public var id: String
    /// Absolute host path of an image (ISO, IMG).
    public var path: String
    public var bus: StorageBus
    enum CodingKeys: String, CodingKey, CaseIterable { case id, path, bus }
    public static let knownKeys = Set(CodingKeys.allCases.map(\.rawValue))
}

public struct PlatformConfig: ExtensibleFields {
    /// Base64 `VZGenericMachineIdentifier`/`VZMacMachineIdentifier` data. Part of the device set, so the
    /// guest keeps its identity across restarts; a clone gets a new one.
    public var machineIdentifier: String?
    enum CodingKeys: String, CodingKey, CaseIterable { case machineIdentifier }
    public static let knownKeys = Set(CodingKeys.allCases.map(\.rawValue))
}

public struct NetworkConfig: ExtensibleFields {
    public enum Mode: String, Codable, Sendable { case nat, bridged, none }
    public var id: String
    public var mode: Mode
    /// Locally administered unicast MAC, persisted so the guest keeps its leases.
    public var macAddress: String
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
    enum CodingKeys: String, CodingKey, CaseIterable { case id, proto, hostAddress, hostPort, guestPort, origin }
    public static let knownKeys = Set(CodingKeys.allCases.map(\.rawValue))
}

public struct ShareConfig: ExtensibleFields {
    public var id: String
    public var name: String
    public var hostPath: String
    public var readOnly: Bool
    enum CodingKeys: String, CodingKey, CaseIterable { case id, name, hostPath, readOnly }
    public static let knownKeys = Set(CodingKeys.allCases.map(\.rawValue))
}

public struct AudioConfig: ExtensibleFields {
    public var output: Bool
    public var input: Bool
    enum CodingKeys: String, CodingKey, CaseIterable { case output, input }
    public static let knownKeys = Set(CodingKeys.allCases.map(\.rawValue))
}

public struct ClipboardConfig: ExtensibleFields {
    public enum Mode: String, Codable, Sendable { case both, hostToGuest, guestToHost, off }
    public var mode: Mode
    /// Whether agents (MCP, non-interactive CLI) may read or write the clipboard content.
    public var allowWithAgents: Bool
    enum CodingKeys: String, CodingKey, CaseIterable { case mode, allowWithAgents }
    public static let knownKeys = Set(CodingKeys.allCases.map(\.rawValue))
}

public struct VZConfig: ExtensibleFields {
    public var rosetta: Bool
    public var nestedVirtualization: Bool
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
    enum CodingKeys: String, CodingKey, CaseIterable { case tpm, secureBoot, gpu, storageBus, smbiosUUID }
    public static let knownKeys = Set(CodingKeys.allCases.map(\.rawValue))
}

public struct AgentConfig: ExtensibleFields {
    public enum Transport: String, Codable, Sendable { case auto, vsock, virtioSerial, tcp }
    public var transport: Transport
    enum CodingKeys: String, CodingKey, CaseIterable { case transport }
    public static let knownKeys = Set(CodingKeys.allCases.map(\.rawValue))
}

public struct MCPConfig: ExtensibleFields {
    public var policy: PolicyLevel
    public var confirmExec: Bool
    public var autoSnapshot: Bool
    public var auditTypedText: Bool
    /// HMAC over the VM id and these settings, written only by the app. Missing or wrong → policy `off`.
    public var tag: String?
    enum CodingKeys: String, CodingKey, CaseIterable { case policy, confirmExec, autoSnapshot, auditTypedText, tag }
    public static let knownKeys = Set(CodingKeys.allCases.map(\.rawValue))
}

public struct UIConfig: ExtensibleFields {
    public enum CloseAction: String, Codable, Sendable { case keepRunning, suspend, stop }
    public var closeAction: CloseAction
    public var icon: String?
    enum CodingKeys: String, CodingKey, CaseIterable { case closeAction, icon }
    public static let knownKeys = Set(CodingKeys.allCases.map(\.rawValue))
}

public struct WindowsConfig: ExtensibleFields {
    public var eulaAcceptedAt: Date?
    enum CodingKeys: String, CodingKey, CaseIterable { case eulaAcceptedAt }
    public static let knownKeys = Set(CodingKeys.allCases.map(\.rawValue))
}

extension VMConfigFields {
    /// A new VM's config with VMPane's defaults for `os`.
    public static func new(id: UUID = UUID(), name: String, os: GuestOS, diskGiB: Int = 64, macAddress: String) -> VMConfigFields {
        let backend: BackendKind = os == .windows ? .qemu : .vz
        return VMConfigFields(
            schemaVersion: schemaVersion, id: id, name: name, os: os, backend: backend,
            cpu: Extensible(CPUConfig(count: 4)),
            memory: Extensible(MemoryConfig(mib: os == .windows ? 8192 : 4096, balloon: true)),
            display: Extensible(DisplayConfig(widthPx: 1920, heightPx: 1200, ppi: 144, autoResize: true, scaling: .retina)),
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
            windows: os == .windows ? Extensible(WindowsConfig(eulaAcceptedAt: nil)) : nil)
    }
}
