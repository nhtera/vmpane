import Foundation
import VMPaneCore

/// How a disk is attached to the guest.
public enum VZDiskKind: Sendable, Equatable { case virtioBlock, usbMassStorage }

/// Everything a Virtualization.framework VM is made of, as plain data. Built from the config by
/// `VZPlanBuilder` (unit-tested without the virtualization entitlement) and turned into a
/// `VZVirtualMachineConfiguration` by `VZMaterializer`.
public struct VZPlan: Sendable, Equatable {
    public enum Platform: Sendable, Equatable {
        /// Linux: generic platform with a persisted machine identifier and an EFI variable store.
        case generic(machineIdentifier: Data, efiVariableStore: URL, nestedVirtualization: Bool)
    }

    public struct Disk: Sendable, Equatable {
        public var url: URL
        public var readOnly: Bool
        public var kind: VZDiskKind
    }

    public struct Display: Sendable, Equatable {
        public var widthPx: Int
        public var heightPx: Int
    }

    public struct NIC: Sendable, Equatable {
        public var macAddress: String
    }

    public struct Share: Sendable, Equatable {
        public var name: String
        public var url: URL
        public var readOnly: Bool
    }

    public var platform: Platform
    public var cpuCount: Int
    public var memoryBytes: UInt64
    public var disks: [Disk]
    public var display: Display
    public var networks: [NIC]
    public var audioOutput: Bool
    public var audioInput: Bool
    public var balloon: Bool
    public var spiceClipboard: Bool
    /// virtiofs shares, all under one tag (`vmpane-shares`).
    public var shares: [Share]
    public var rosetta: Bool
    /// Guest serial console (hvc0) is appended here.
    public var serialLog: URL

    public static let sharesTag = "vmpane-shares"
    public static let rosettaTag = "rosetta"
}

public enum VZPlanError: Error, Equatable, Sendable {
    case unsupportedGuest(GuestOS)
    case missingMachineIdentifier
    case invalidMachineIdentifier
    case invalidMACAddress(String)
    case bridgedNetworkingUnavailable
    case missingFile(String)
}

/// Maps a VM's config to a `VZPlan`.
public enum VZPlanBuilder {
    public static func plan(
        _ config: VMConfigV1, bundle: VMBundle,
        fileExists: (URL) -> Bool = {
            FileManager.default.fileExists(atPath: $0.path)
        }
    ) throws -> VZPlan {
        guard config.os == .linux else { throw VZPlanError.unsupportedGuest(config.os) }
        guard let encoded = config.platform.machineIdentifier else { throw VZPlanError.missingMachineIdentifier }
        guard let identifier = Data(base64Encoded: encoded), !identifier.isEmpty else { throw VZPlanError.invalidMachineIdentifier }

        var disks: [VZPlan.Disk] = []
        for disk in config.disks {
            let url = try bundle.fileURL(relativePath: disk.file)
            guard fileExists(url) else { throw VZPlanError.missingFile(disk.file) }
            disks.append(.init(url: url, readOnly: false, kind: disk.bus == .usb ? .usbMassStorage : .virtioBlock))
        }
        for removable in config.removable {
            let url = URL(fileURLWithPath: removable.path)
            guard fileExists(url) else { throw VZPlanError.missingFile(removable.path) }
            disks.append(.init(url: url, readOnly: true, kind: removable.bus == .virtio ? .virtioBlock : .usbMassStorage))
        }

        var networks: [VZPlan.NIC] = []
        for nic in config.network {
            switch nic.mode {
            case .none: continue
            case .bridged: throw VZPlanError.bridgedNetworkingUnavailable
            case .nat:
                guard isValidMAC(nic.macAddress) else { throw VZPlanError.invalidMACAddress(nic.macAddress) }
                networks.append(.init(macAddress: nic.macAddress.lowercased()))
            }
        }

        return VZPlan(
            platform: .generic(
                machineIdentifier: identifier,
                efiVariableStore: bundle.auxDirectory.appendingPathComponent("efi_vars.fd"),
                nestedVirtualization: config.vz?.nestedVirtualization ?? false),
            cpuCount: config.cpu.count,
            memoryBytes: UInt64(config.memory.mib) << 20,
            disks: disks,
            display: .init(widthPx: config.display.widthPx, heightPx: config.display.heightPx),
            networks: networks,
            audioOutput: config.audio.output,
            audioInput: config.audio.input,
            balloon: config.memory.balloon,
            spiceClipboard: config.clipboard.mode != .off,
            shares: config.shares.map { .init(name: $0.name, url: URL(fileURLWithPath: $0.hostPath), readOnly: $0.readOnly) },
            rosetta: config.vz?.rosetta ?? false,
            serialLog: bundle.logsDirectory.appendingPathComponent("serial.log"))
    }

    static func isValidMAC(_ mac: String) -> Bool {
        let parts = mac.split(separator: ":")
        return parts.count == 6 && parts.allSatisfy { $0.count == 2 && UInt8($0, radix: 16) != nil }
    }
}
