import Foundation
import VMPaneCore

/// The helper's child processes (QEMU, swtpm, …): spawned with only the descriptors they need and
/// recorded durably in `run/<sid>.children` before the helper relies on them, so a successor can reap
/// them after a crash.
public final class ChildProcessRegistry: @unchecked Sendable {
    private let runFiles: RunFiles
    /// The helper the children belong to (recorded with each child).
    private let owner: ProcessRecord
    private let lock = NSLock()
    private var children: [ProcessRecord] = []

    public init(runFiles: RunFiles, owner: ProcessRecord = .this) {
        self.runFiles = runFiles
        self.owner = owner
    }

    /// Spawns and records a child. Disk writers pass the bundle lock in `options.inheriting`.
    @discardableResult
    public func spawn(_ executable: URL, _ options: ChildSpawner.Options) throws -> ProcessRecord {
        let child = try ChildSpawner.spawnSuspended(executable, options)
        do {
            try lock.withLock {
                children.append(child)
                try runFiles.writeChildren(children, parent: owner)
            }
        } catch {
            lock.withLock { children.removeAll { $0 == child } }
            ChildSpawner.discard(child)
            throw error
        }
        ChildSpawner.resume(child)
        return child
    }

    /// Forgets a child that exited on its own.
    public func remove(_ child: ProcessRecord) throws {
        try lock.withLock {
            children.removeAll { $0 == child }
            try runFiles.writeChildren(children, parent: owner)
        }
    }

    public var current: [ProcessRecord] { lock.withLock { children } }

    /// Stops every child (verified) and waits for each.
    public func terminateAll() {
        let all = lock.withLock { children }
        for child in all { child.terminate() }
        lock.withLock {
            children.removeAll()
            try? runFiles.writeChildren([], parent: owner)
        }
    }
}
