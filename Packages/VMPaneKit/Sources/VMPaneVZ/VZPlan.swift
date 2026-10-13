import Foundation
import VMPaneCore

/// The files of a macOS guest's platform, in `current/aux/`.
public struct VZMacAux: Sendable, Equatable {
    public var hardwareModel: URL
    public var machineIdentifier: URL
    public var auxiliaryStorage: URL

    public init(directory: URL) {
        hardwareModel = directory.appendingPathComponent("HardwareModel")
        machineIdentifier = directory.appendingPathComponent("MachineIdentifier")
        auxiliaryStorage = directory.appendingPathComponent("AuxiliaryStorage")
    }
}

/// How a disk is attached to the guest.
public enum VZDiskKind: Sendable, Equatable { case virtioBlock, usbMassStorage }

/// Everything a Virtualization.framework VM is made of, as plain data. Built from the config by
/// `VZPlanBuilder` (unit-tested without the virtualization entitlement) and turned into a
/// `VZVirtualMachineConfiguration` by `VZMaterializer`.
public struct VZPlan: Sendable, Equatable {
    public enum Platform: Sendable, Equatable {
        /// Linux: generic platform with a persisted machine identifier and an EFI variable store.
        case generic(machineIdentifier: Data, efiVariableStore: URL, nestedVirtualization: Bool)
        /// macOS: hardware model, machine identifier and auxiliary storage from `current/aux/`. When the
        /// guest is not installed yet, `installFrom` names the restore image and the installer makes them.
        case mac(aux: VZMacAux, installFrom: URL?)
    }

    public struct Disk: Sendable, Equatable {
        public var url: URL
        public var readOnly: Bool
        public var kind: VZDiskKind
    }

    public struct Display: Sendable, Equatable {
        public var widthPx: Int
        public var heightPx: Int
        /// `.standard`: the guest gets one pixel per point of the window (a Linux console reads at its usual size).
        public var scaling: DisplayConfig.Scaling = .retina
        public var autoResize = true

        /// The guest size a `.standard` display boots at: the configured size in points (half its pixels), even and at
        /// least 800 × 600.
        public var standardBootSize: (width: Int, height: Int) {
            func even(_ value: Int, atLeast low: Int) -> Int { max(value / 4 * 2, low) }
            return (even(widthPx, atLeast: 800), even(heightPx, atLeast: 600))
        }
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
    /// Display density for macOS guests (Mac graphics device).
    public var pixelsPerInch: Int
    /// Guest serial console (hvc0) is appended here.
    public var serialLog: URL
    /// The guest tools for this guest OS (agent and installer), shared read-only: tag `vmpane-tools` on Linux,
    /// `vmpane-tools` under the automount share on macOS. Nil when the app has none.
    public var guestTools: URL?

    public static let sharesTag = "vmpane-shares"
    public static let rosettaTag = "rosetta"
    public static let guestToolsTag = "vmpane-tools"
}

public enum VZPlanError: Error, Equatable, Sendable {
    case unsupportedGuest(GuestOS)
    /// A macOS guest that is neither installed nor has a restore image to install from.
    case notInstalled
    case missingMachineIdentifier
    case invalidMachineIdentifier
    case invalidMACAddress(String)
    case bridgedNetworkingUnavailable
    case missingFile(String)
}

/// Maps a VM's config to a `VZPlan`.
public enum VZPlanBuilder {
    public static func plan(
        _ config: VMConfigV1, bundle: VMBundle, guestTools: URL? = nil,
        fileExists: (URL) -> Bool = {
            FileManager.default.fileExists(atPath: $0.path)
        }
    ) throws -> VZPlan {
        let platform = try platformPlan(config, bundle: bundle, fileExists: fileExists)

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
            platform: platform,
            cpuCount: config.cpu.count,
            memoryBytes: UInt64(config.memory.mib) << 20,
            disks: disks,
            display: .init(
                widthPx: config.display.widthPx, heightPx: config.display.heightPx,
                scaling: config.os == .macos ? .retina : config.display.scaling, autoResize: config.display.autoResize),
            networks: networks,
            audioOutput: config.audio.output,
            audioInput: config.audio.input,
            balloon: config.memory.balloon,
            spiceClipboard: config.os == .linux && config.clipboard.mode != .off,  // macOS guests: agent (Phase 07)
            shares: config.shares.map { .init(name: $0.name, url: URL(fileURLWithPath: $0.hostPath), readOnly: $0.readOnly) },
            rosetta: config.os == .linux && (config.vz?.rosetta ?? false),
            pixelsPerInch: config.display.ppi,
            serialLog: bundle.logsDirectory.appendingPathComponent("serial.log"),
            guestTools: guestTools)
    }

    private static func platformPlan(_ config: VMConfigV1, bundle: VMBundle, fileExists: (URL) -> Bool) throws -> VZPlan.Platform {
        switch config.os {
        case .linux:
            guard let encoded = config.platform.machineIdentifier else { throw VZPlanError.missingMachineIdentifier }
            guard let identifier = Data(base64Encoded: encoded), !identifier.isEmpty else { throw VZPlanError.invalidMachineIdentifier }
            return .generic(
                machineIdentifier: identifier, efiVariableStore: bundle.auxDirectory.appendingPathComponent("efi_vars.fd"),
                nestedVirtualization: config.vz?.nestedVirtualization ?? false)
        case .macos:
            let aux = VZMacAux(directory: bundle.auxDirectory)
            // The install source is dropped only once macOS installed (`VZBackend.installed`): while it is set, an
            // install was never finished (e.g. stopped half-way) and starts again, whatever platform files exist.
            if let image = config.install?.restoreImage {
                guard fileExists(URL(fileURLWithPath: image)) else { throw VZPlanError.notInstalled }
                return .mac(aux: aux, installFrom: URL(fileURLWithPath: image))
            }
            guard [aux.hardwareModel, aux.machineIdentifier, aux.auxiliaryStorage].allSatisfy(fileExists) else {
                throw VZPlanError.notInstalled
            }
            return .mac(aux: aux, installFrom: nil)
        case .windows:
            throw VZPlanError.unsupportedGuest(config.os)
        }
    }

    static func isValidMAC(_ mac: String) -> Bool {
        let parts = mac.split(separator: ":")
        return parts.count == 6 && parts.allSatisfy { $0.count == 2 && UInt8($0, radix: 16) != nil }
    }
}
