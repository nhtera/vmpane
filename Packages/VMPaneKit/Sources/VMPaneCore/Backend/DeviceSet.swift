import CryptoKit
import Foundation

/// The guest-visible hardware of a VM. Saved RAM state (suspend, live snapshots) is only valid for the
/// device set it was taken with. Settings that do not change devices (name, UI, MCP, clipboard, port
/// forwards, unknown keys) are left out, so editing them, or a schema-only migration, keeps states valid.
public struct DeviceSet: Codable, Equatable, Sendable {
    public struct Disk: Codable, Equatable, Sendable { public var id: String; public var bus: StorageBus; public var sizeGiB: Int }
    public struct Removable: Codable, Equatable, Sendable { public var id: String; public var bus: StorageBus }
    public struct NIC: Codable, Equatable, Sendable { public var id: String; public var mode: String; public var macAddress: String }
    public struct Share: Codable, Equatable, Sendable { public var id: String; public var name: String; public var readOnly: Bool }

    public var backend: BackendKind
    public var os: GuestOS
    public var cpuCount: Int
    public var memoryMiB: Int
    public var balloon: Bool
    public var disks: [Disk]
    public var removable: [Removable]
    public var machineIdentifier: String?
    public var network: [NIC]
    public var shares: [Share]
    public var audioOutput: Bool
    public var audioInput: Bool
    public var rosetta: Bool?
    public var nestedVirtualization: Bool?
    public var tpm: Bool?
    public var secureBoot: Bool?
    public var gpu: String?
    public var storageBus: StorageBus?
    public var smbiosUUID: UUID?
    /// The backend's device layout for a given config (see `layoutVersions`).
    public var layout: Int

    /// Bump a backend's version when it changes the devices it builds for the same config (VZ 2: an XHCI
    /// controller on every VM), so saved states from the old layout are discarded instead of failing to
    /// restore.
    public static let layoutVersions: [BackendKind: Int] = [.vz: 2, .qemu: 1]

    public init(_ config: VMConfigV1) {
        layout = Self.layoutVersions[config.backend] ?? 1
        backend = config.backend
        os = config.os
        cpuCount = config.cpu.count
        memoryMiB = config.memory.mib
        balloon = config.memory.balloon
        disks = config.disks.map { Disk(id: $0.id, bus: $0.bus, sizeGiB: $0.sizeGiB) }
        removable = config.removable.map { Removable(id: $0.id, bus: $0.bus) }
        machineIdentifier = config.platform.machineIdentifier
        network = config.network.map { NIC(id: $0.id, mode: $0.mode.rawValue, macAddress: MachineIdentity.normalizedMAC($0.macAddress)) }
        shares = config.shares.map { Share(id: $0.id, name: $0.name, readOnly: $0.readOnly) }
        audioOutput = config.audio.output
        audioInput = config.audio.input
        rosetta = config.vz?.rosetta
        nestedVirtualization = config.vz?.nestedVirtualization
        tpm = config.qemu?.tpm
        secureBoot = config.qemu?.secureBoot
        gpu = config.qemu?.gpu.rawValue
        storageBus = config.qemu?.storageBus
        smbiosUUID = config.qemu?.smbiosUUID
    }

    /// SHA-256 (hex) of the canonical encoding.
    public var hash: String {
        let data = (try? CanonicalJSON.encoder().encode(self)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
