import Foundation
import Observation
import VMPaneControl
import VMPaneCore

/// The VM's snapshots, newest first, and taking, renaming, restoring and deleting them: through its helper while one
/// runs it, else straight on the stopped VM's bundle (`LibraryOps`).
@MainActor
@Observable
public final class SnapshotsModel {
    public private(set) var snapshots: [SnapshotMeta] = []
    public private(set) var busy = false
    public var lastError: String?

    private enum Source {
        case helper(HelperChannel)
        case stopped(VMBundle, LibraryOps)
    }

    @ObservationIgnored private let source: Source

    public init(channel: HelperChannel) {
        source = .helper(channel)
    }

    /// A stopped VM's, with no helper.
    public init(stopped bundle: VMBundle, ops: LibraryOps) {
        source = .stopped(bundle, ops)
    }

    public func reload() async {
        await run {
            switch self.source {
            case .helper(let channel):
                let list = try await channel.call(ControlMethod.vmSnapshotList.rawValue, params: nil, timeout: .seconds(10))
                let decoded = try CanonicalJSON.decoder().decode([SnapshotMeta].self, from: CanonicalJSON.encoder().encode(list))
                self.snapshots = decoded.sorted { $0.createdAt > $1.createdAt }
            case .stopped(let bundle, let ops):
                self.snapshots = try await Blocking.run { try ops.snapshots(of: bundle) }
            }
        }
    }

    /// A live snapshot (memory included) of a running VM, a disk snapshot of a stopped one.
    public func take(name: String, running: Bool) async {
        await run {
            switch self.source {
            case .helper(let channel):
                let params: JSONValue = ["name": .string(name), "kind": running ? "live" : "disk"]
                _ = try await channel.call(ControlMethod.vmSnapshotCreate.rawValue, params: params, timeout: .seconds(300))
            case .stopped(let bundle, let ops):
                _ = try await Blocking.run { try ops.createSnapshot(named: name, in: bundle) }
            }
        }
        await reload()
    }

    public func restore(_ id: UUID) async {
        await run {
            switch self.source {
            case .helper(let channel):
                _ = try await channel.call(
                    ControlMethod.vmSnapshotRestore.rawValue, params: ["id": .string(id.uuidString)], timeout: .seconds(300))
            case .stopped(let bundle, let ops):
                try await Blocking.run { try ops.restoreSnapshot(id, in: bundle) }
            }
        }
        await reload()
    }

    public func rename(_ id: UUID, to name: String) async {
        await run {
            switch self.source {
            case .helper(let channel):
                _ = try await channel.call(
                    ControlMethod.vmSnapshotRename.rawValue, params: ["id": .string(id.uuidString), "name": .string(name)],
                    timeout: .seconds(30))
            case .stopped(let bundle, let ops):
                try await Blocking.run { try ops.renameSnapshot(id, to: name, in: bundle) }
            }
        }
        await reload()
    }

    public func delete(_ id: UUID) async {
        await run {
            switch self.source {
            case .helper(let channel):
                _ = try await channel.call(
                    ControlMethod.vmSnapshotDelete.rawValue, params: ["id": .string(id.uuidString)], timeout: .seconds(60))
            case .stopped(let bundle, let ops):
                try await Blocking.run { try ops.deleteSnapshot(id, in: bundle) }
            }
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
            lastError = VMLibrary.problem(error, at: URL(fileURLWithPath: "/"))
        }
    }
}
