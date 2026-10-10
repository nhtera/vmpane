import Foundation
import VMPaneControl
import VMPaneCore

/// Snapshot requests. Disk snapshots need the VM stopped (a running guest's file systems are only
/// consistent with the agent's fs freeze, Phase 07). Live snapshots pause the VM, save its RAM state as
/// `current/state/suspend.*`, commit it with the disks, and resume; any failure resumes the VM.
extension HelperController {
    private struct CreateParams: Decodable {
        var name: String
        var kind: SnapshotMeta.Kind
        var origin: SnapshotMeta.Origin?
    }

    private struct IDParams: Decodable { var id: UUID }

    func snapshotRequest(_ method: String, _ params: JSONValue?) async -> Result<JSONValue, RPCError> {
        let store = SnapshotStore(lock: prepared.lock)
        do {
            switch ControlMethod(rawValue: method) {
            case .vmSnapshotList?:
                return RPCParams.encode(try await Blocking.run { try store.list() })
            case .vmSnapshotCreate?:
                let create = try RPCParams.decode(CreateParams.self, from: params).get()
                return RPCParams.encode(try await createSnapshot(create.name, kind: create.kind, origin: create.origin ?? .user))
            case .vmSnapshotDelete?:
                let id = try RPCParams.decode(IDParams.self, from: params).get().id
                try await Blocking.run { try store.delete(id) }
                return .success(.object([:]))
            case .vmSnapshotRestore?:
                return try await restoreSnapshot(try RPCParams.decode(IDParams.self, from: params).get().id)
            default:
                return .failure(RPCError(.methodNotFound, "unknown snapshot method"))
            }
        } catch let error as RPCError {
            return .failure(error)
        } catch SnapshotError.notFound(let id) {
            return .failure(RPCError(.invalidParams, "no snapshot \(id)"))
        } catch let error as InsufficientSpace {
            return .failure(
                RPCError(.insufficientSpace, "needs \(error.requiredBytes >> 30) GiB free, \(error.availableBytes >> 30) GiB available"))
        } catch {
            return .failure(RPCError(.internalError, String(describing: error)))
        }
    }

    /// Tagged with the hardware the VM runs with; a stopped VM's disks follow the saved config.
    private var snapshotContext: SnapshotContext {
        let hardware = state == .stopped || state == .error ? config : runningConfig ?? config
        return SnapshotContext(deviceSetHash: DeviceSet(hardware).hash, hostBuild: Self.hostBuild, backendVersion: VMPane.version)
    }

    func createSnapshot(_ name: String, kind: SnapshotMeta.Kind, origin: SnapshotMeta.Origin) async throws -> SnapshotMeta {
        let store = SnapshotStore(lock: prepared.lock)
        let context = snapshotContext
        switch kind {
        case .disk:
            guard state == .stopped else {
                throw RPCError(.unsupportedLive, "a disk snapshot needs the VM stopped; take a live snapshot instead")
            }
            return try await Blocking.run { try store.create(name: name, kind: .disk, origin: origin, context: context) }
        case .live:
            guard let backend, backend.capabilities.contains(.liveSnapshot) else {
                throw RPCError(.backendUnavailable, "this VM's backend cannot take live snapshots")
            }
            guard state == .running || state == .paused else {
                throw RPCError(.invalidState, "a live snapshot needs the VM running")
            }
            return try await liveSnapshot(backend, name: name, origin: origin, context: context)
        }
    }

    private func liveSnapshot(
        _ backend: VMBackend, name: String, origin: SnapshotMeta.Origin,
        context: SnapshotContext
    ) async throws -> SnapshotMeta {
        let store = SnapshotStore(lock: prepared.lock)
        let (bundle, directory) = (prepared.lock.bundle, stateDirectory)
        let memory = UInt64(config.memory.mib) << 20
        try await Blocking.run { try SpaceGuard.check(memoryBytes: memory, at: bundle.url) }
        let wasRunning = state == .running
        if wasRunning {
            try await backend.pause()
            transition(.paused)
        }
        do {
            await clearSavedState()
            try await backend.saveState(to: directory)
            try await writeStateMeta()
            let meta = try await Blocking.run {
                let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                return try store.create(name: name, kind: .live, origin: origin, context: context, stateFiles: files, memoryBytes: memory)
            }
            await clearSavedState()  // the state now belongs to the snapshot
            if wasRunning {
                try await backend.resume()
                transition(.resumed)
            }
            return meta
        } catch {
            await clearSavedState()
            if wasRunning {
                try? await backend.resume()
                transition(.resumed)
            }
            throw error
        }
    }

    /// Restores a snapshot. A running VM is powered off first, then started again: from the snapshot's
    /// RAM state when it is live and still matches the hardware, otherwise with a cold boot.
    private func restoreSnapshot(_ id: UUID) async throws -> Result<JSONValue, RPCError> {
        let store = SnapshotStore(lock: prepared.lock)
        guard let meta = try await Blocking.run({ try store.list() }).first(where: { $0.id == id }) else {
            throw SnapshotError.notFound(id)
        }
        // A live snapshot's memory cannot be read on a locked Mac: refuse before stopping the running VM.
        if meta.kind == .live, isSessionLocked() {
            throw RPCError(.macLocked, "This Mac is locked. Unlock it to restore a live snapshot (its saved memory is encrypted).")
        }
        let wasActive = [.running, .paused, .starting].contains(state)
        if wasActive, let backend {
            transition(.stop)
            try await backend.stop(.force)
            guard await waitForState(.stopped, timeout: .seconds(15)) else {
                throw RPCError(.busy, "the VM did not stop for the restore")
            }
        }
        guard state == .stopped || state == .error else {
            throw RPCError(.invalidState, "cannot restore while \(state.rawValue)")
        }
        let generation = try await Blocking.run { try store.restore(id) }
        var result: [String: JSONValue] = ["generationId": .string(generation.generationId.uuidString)]
        if let backend, wasActive || meta.kind == .live {
            let resumed = try await startVM(backend, headless: lastStartHeadless)
            result["resumed"] = .bool(resumed)
            if meta.kind == .live && !resumed {
                result["message"] =
                    "The snapshot's memory state could not be restored on this VM (its hardware changed), so it started fresh."
            }
        }
        result["state"] = .string(state.rawValue)
        return .success(.object(result))
    }
}
