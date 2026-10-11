import Foundation
import Observation
import VMPaneControl
import VMPaneCore

/// The VM's snapshots, newest first, and taking, restoring and deleting them through the helper.
@MainActor
@Observable
public final class SnapshotsModel {
    public private(set) var snapshots: [SnapshotMeta] = []
    public private(set) var busy = false
    public var lastError: String?

    @ObservationIgnored private let channel: HelperChannel

    public init(channel: HelperChannel) {
        self.channel = channel
    }

    public func reload() async {
        await run {
            let list = try await self.channel.call(ControlMethod.vmSnapshotList.rawValue, params: nil, timeout: .seconds(10))
            let decoded = try CanonicalJSON.decoder().decode([SnapshotMeta].self, from: CanonicalJSON.encoder().encode(list))
            self.snapshots = decoded.sorted { $0.createdAt > $1.createdAt }
        }
    }

    /// A live snapshot (memory included) of a running VM, a disk snapshot of a stopped one.
    public func take(name: String, running: Bool) async {
        await run {
            let params: JSONValue = ["name": .string(name), "kind": running ? "live" : "disk"]
            _ = try await self.channel.call(ControlMethod.vmSnapshotCreate.rawValue, params: params, timeout: .seconds(300))
        }
        await reload()
    }

    public func restore(_ id: UUID) async {
        await run {
            _ = try await self.channel.call(
                ControlMethod.vmSnapshotRestore.rawValue, params: ["id": .string(id.uuidString)], timeout: .seconds(300))
        }
    }

    public func delete(_ id: UUID) async {
        await run {
            _ = try await self.channel.call(
                ControlMethod.vmSnapshotDelete.rawValue, params: ["id": .string(id.uuidString)], timeout: .seconds(60))
        }
        await reload()
    }

    /// What restoring `snapshot` throws away, for the confirmation.
    public static func restoreWarning(_ snapshot: SnapshotMeta) -> String {
        let kind = snapshot.kind == .live ? "returns to the running state it had" : "returns to its disks as they were (a fresh start)"
        return "The VM \(kind) at \(snapshot.createdAt.formatted(date: .abbreviated, time: .shortened)). "
            + "Everything since then is lost unless you take a snapshot first."
    }

    private func run(_ body: () async throws -> Void) async {
        busy = true
        defer { busy = false }
        do {
            try await body()
        } catch let error as RPCError {
            lastError = error.message
        } catch {
            lastError = String(describing: error)
        }
    }
}
