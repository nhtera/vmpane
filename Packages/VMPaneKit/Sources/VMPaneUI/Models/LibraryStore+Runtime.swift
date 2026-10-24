import Foundation
import VMPaneControl
import VMPaneCore

/// A VM's helper from before an app update (issue #12): a helper never quits on its own, so a stopped VM's old helper
/// would start the old QEMU again. Its next start gets a fresh helper from this app's runtime; a VM still running on
/// an older one (or suspended by it) says that a restart takes the update.
extension LibraryStore {
    /// The runtime of the live helper of VM `id` (its pid record), nil when no helper runs it.
    nonisolated static func helperRuntime(_ id: UUID, paths: VMPanePaths) -> String? {
        guard let record = RunFiles(paths: paths, sid: ShortID(id)).readHelper(), record.process.isAlive else { return nil }
        return record.runtimeVersion
    }

    /// Whether VM `id`'s live helper runs on another runtime than this app's (never without `currentRuntime`).
    func helperIsOutdated(_ id: UUID) async -> Bool {
        let paths = library.paths
        let current = currentRuntime
        return await Blocking.run {
            Self.helperRuntime(id, paths: paths).map { RuntimeStore.isOutdated($0, current: current()) } ?? false
        }
    }

    /// Whether starting VM `id` needs a helper launched: none runs it, or its helper is from an older runtime with
    /// the VM stopped (not suspended), which then quits first.
    func needsHelperLaunch(_ id: UUID) async throws -> Bool {
        guard let row = row(id), row.state != nil else { return true }
        guard row.state == .stopped || row.state == .error, !row.suspended, await helperIsOutdated(id) else { return false }
        return try await retireOutdatedHelper(id)
    }

    /// Marks the row of VM `id` when its helper is outdated.
    func noteRuntime(of id: UUID) async {
        let outdated = await helperIsOutdated(id)
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[index].outdatedRuntime = outdated
    }

    /// Lets the outdated helper of VM `id` go once it says its VM is still stopped (not suspended), and waits until
    /// it has quit and its watch has ended, so the start launches one from this app's runtime and attaches to that
    /// one. False: the VM started meanwhile, so its helper stays.
    private func retireOutdatedHelper(_ id: UUID) async throws -> Bool {
        let info = try await links.call(id, ControlMethod.vmInfo.rawValue, params: nil)
        let stopped = [VMRunState.stopped.rawValue, VMRunState.error.rawValue].contains(info["state"]?.stringValue ?? "")
        guard stopped, info["suspended"] != true else { return false }
        _ = try await links.call(id, ControlMethod.helperShutdown.rawValue, params: nil)
        let paths = library.paths
        let deadline = ContinuousClock.now + .seconds(15)
        while await Blocking.run({ Self.helperRuntime(id, paths: paths) }) != nil || row(id)?.state != nil {
            guard ContinuousClock.now < deadline else {
                let name = row(id)?.name ?? "The VM"
                throw RPCError(.busy, "\(name)'s helper from the previous version of VMPane did not quit: start it again in a moment")
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        return true
    }
}
