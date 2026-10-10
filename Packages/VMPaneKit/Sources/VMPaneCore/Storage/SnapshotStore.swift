import Darwin
import Foundation

public enum SnapshotError: Error, Equatable, Sendable {
    case notFound(UUID)
    /// A live snapshot needs the RAM state files from the paused backend.
    case missingState
}

/// Steps of a snapshot create or restore, for crash-injection tests.
public enum SnapshotStep: String, Sendable, CaseIterable {
    case createdPartial, cloned, wroteMeta, committed
    case builtStaging, wroteJournal, swapped, removedOldSet
}

/// Facts recorded in a snapshot's meta.json that the store cannot know itself.
public struct SnapshotContext: Sendable {
    public var deviceSetHash: String
    public var hostBuild: String
    public var backendVersion: String

    public init(deviceSetHash: String, hostBuild: String, backendVersion: String) {
        self.deviceSetHash = deviceSetHash
        self.hostBuild = hostBuild
        self.backendVersion = backendVersion
    }
}

/// Snapshots of a bundle's live set (`current/`), as APFS clones.
///
/// Durability: a snapshot is committed by renaming `snapshots/<id>.partial` to `snapshots/<id>` after its
/// meta.json is durable. A restore builds `.restore-<generation>`, writes `restore.journal`, then swaps the
/// directory with `current/` in one `renameatx_np(RENAME_SWAP)`. Nothing is cleaned up on failure: a
/// crash gets no cleanup either, so `recover()` (run by every lock holder) is the one recovery path.
///
/// All methods need the bundle lock; restore also needs the backend stopped with all children reaped.
public struct SnapshotStore: Sendable {
    public let lock: BundleLock
    /// Called after each step; throwing simulates a crash there (tests only).
    var faultInjector: (@Sendable (SnapshotStep) throws -> Void)?

    public init(lock: BundleLock) {
        self.lock = lock
    }

    private var bundle: VMBundle { lock.bundle }
    private var fm: FileManager { FileManager.default }

    private func step(_ step: SnapshotStep) throws {
        try faultInjector?(step)
    }

    private func directory(_ id: UUID) -> URL {
        bundle.snapshotsDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    // MARK: - Create

    @discardableResult
    /// `memoryBytes` (guest RAM) is required for live snapshots: `SpaceGuard` refuses them on a nearly full volume.
    public func create(
        name: String, kind: SnapshotMeta.Kind, origin: SnapshotMeta.Origin, context: SnapshotContext,
        stateFiles: [URL] = [], memoryBytes: UInt64? = nil, now: Date = Date(),
        availableSpace: (URL) throws -> UInt64 = SpaceGuard.availableBytes
    ) throws -> SnapshotMeta {
        if kind == .live {
            guard !stateFiles.isEmpty, let memoryBytes else { throw SnapshotError.missingState }
            try SpaceGuard.check(memoryBytes: memoryBytes, at: bundle.url, available: availableSpace)
        }
        var generation = try Generation.read(from: bundle.generationURL)
        let id = UUID()
        let partial = bundle.snapshotsDirectory.appendingPathComponent("\(id.uuidString).partial", isDirectory: true)
        try fm.createDirectory(at: partial, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try step(.createdPartial)

        var size: UInt64 = 0
        for entry in try liveEntries() {
            // A running VM's disk can have writes still in the page cache: clonefile copies only what is on
            // disk, so flush first or the snapshot's disk lags the RAM state saved with it.
            Self.flush(entry)
            let target = partial.appendingPathComponent(entry.lastPathComponent)
            try CloneFile.clone(entry, to: target)
            size += Self.allocatedBytes(target)
        }
        if !stateFiles.isEmpty {
            let state = partial.appendingPathComponent("state", isDirectory: true)
            try fm.createDirectory(at: state, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            for file in stateFiles {
                try CloneFile.clone(file, to: state.appendingPathComponent(file.lastPathComponent))
            }
        }
        try DurableWrite.syncTree(partial)  // clones are durable before the meta commits them
        try step(.cloned)

        let meta = SnapshotMeta(
            schemaVersion: SnapshotMeta.schemaVersion, id: id, name: name, createdAt: now,
            parentId: generation.parentSnapshotId, kind: kind, generationId: generation.generationId,
            deviceSetHash: context.deviceSetHash, hostBuild: context.hostBuild, backendVersion: context.backendVersion,
            origin: origin, sizeBytes: size)
        try DurableWrite.write(CanonicalJSON.encode(meta), to: partial.appendingPathComponent("meta.json"))
        try step(.wroteMeta)

        guard rename(partial.path, directory(id).path) == 0 else { throw POSIXError.current() }
        try DurableWrite.syncDirectory(bundle.snapshotsDirectory)
        try step(.committed)

        generation.parentSnapshotId = id
        try generation.write(to: bundle.generationURL)
        return meta
    }

    // MARK: - List / delete

    /// Committed snapshots, oldest first.
    public func list() throws -> [SnapshotMeta] {
        let entries = try fm.contentsOfDirectory(at: bundle.snapshotsDirectory, includingPropertiesForKeys: nil)
        var metas: [SnapshotMeta] = []
        for entry in entries where UUID(uuidString: entry.lastPathComponent) != nil {
            let metaURL = entry.appendingPathComponent("meta.json")
            guard let data = try? Data(contentsOf: metaURL),
                let meta = try? CanonicalJSON.decoder().decode(SnapshotMeta.self, from: data)
            else { continue }
            metas.append(meta)
        }
        return metas.sorted { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }
    }

    public func delete(_ id: UUID) throws {
        let dir = directory(id)
        guard fm.fileExists(atPath: dir.path) else { throw SnapshotError.notFound(id) }
        let doomed = bundle.snapshotsDirectory.appendingPathComponent("\(id.uuidString).deleting", isDirectory: true)
        guard rename(dir.path, doomed.path) == 0 else { throw POSIXError.current() }
        try DurableWrite.syncDirectory(bundle.snapshotsDirectory)
        try fm.removeItem(at: doomed)
    }

    // MARK: - Restore

    /// Makes snapshot `id` the live set with a new generation. A live snapshot's RAM state comes along,
    /// re-tagged with the new generation (it matches the disks restored with it).
    @discardableResult
    public func restore(_ id: UUID) throws -> Generation {
        let source = directory(id)
        let metaURL = source.appendingPathComponent("meta.json")
        guard let data = try? Data(contentsOf: metaURL),
            let meta = try? CanonicalJSON.decoder().decode(SnapshotMeta.self, from: data)
        else {
            throw SnapshotError.notFound(id)
        }
        let generation = Generation(parentSnapshotId: id)
        let stagingName = ".restore-\(generation.generationId.uuidString)"
        let staging = bundle.url.appendingPathComponent(stagingName, isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        for entry in try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
        where !["meta.json", "state"].contains(entry.lastPathComponent) {
            try CloneFile.clone(entry, to: staging.appendingPathComponent(entry.lastPathComponent))
        }
        let state = staging.appendingPathComponent("state", isDirectory: true)
        let sourceState = source.appendingPathComponent("state", isDirectory: true)
        if meta.kind == .live, fm.fileExists(atPath: sourceState.path) {
            try CloneFile.clone(sourceState, to: state)
            let stateMetaURL = state.appendingPathComponent(StateMeta.fileName)
            if let stateData = try? Data(contentsOf: stateMetaURL),
                var stateMeta = try? CanonicalJSON.decoder().decode(StateMeta.self, from: stateData)
            {
                stateMeta.generationId = generation.generationId
                try DurableWrite.write(CanonicalJSON.encode(stateMeta), to: stateMetaURL)
            }
        } else {
            try fm.createDirectory(at: state, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        try generation.write(to: staging.appendingPathComponent("generation.json"))
        try DurableWrite.syncTree(staging)
        try step(.builtStaging)

        let journal = RestoreJournal(
            schemaVersion: RestoreJournal.schemaVersion, snapshotId: id, staging: stagingName,
            newGenerationId: generation.generationId)
        try DurableWrite.write(CanonicalJSON.encode(journal), to: bundle.restoreJournalURL)
        try step(.wroteJournal)

        guard renameatx_np(AT_FDCWD, bundle.currentDirectory.path, AT_FDCWD, staging.path, UInt32(RENAME_SWAP)) == 0 else {
            throw POSIXError.current()
        }
        try DurableWrite.syncDirectory(bundle.url)
        try step(.swapped)

        try fm.removeItem(at: staging)  // now holds the old set
        try step(.removedOldSet)
        try fm.removeItem(at: bundle.restoreJournalURL)
        try DurableWrite.syncDirectory(bundle.url)
        return generation
    }

    // MARK: - Recovery

    /// Replays an interrupted restore and sweeps leftovers of interrupted operations. Run on every lock take.
    public func recover() throws {
        // Swapped or not, the staging directory now holds the set that lost, and the sweep below removes
        // every `.restore-*` directory inside the bundle. The journal's own path is never trusted: a bundle
        // from elsewhere could name a directory outside it.
        if fm.fileExists(atPath: bundle.restoreJournalURL.path) {
            try fm.removeItem(at: bundle.restoreJournalURL)
        }
        for entry in try fm.contentsOfDirectory(at: bundle.url, includingPropertiesForKeys: nil)
        where entry.lastPathComponent.hasPrefix(".restore-") {
            try fm.removeItem(at: entry)
        }
        for entry in try fm.contentsOfDirectory(at: bundle.snapshotsDirectory, includingPropertiesForKeys: nil) {
            let name = entry.lastPathComponent
            let committed = UUID(uuidString: name) != nil && fm.fileExists(atPath: entry.appendingPathComponent("meta.json").path)
            if !committed { try fm.removeItem(at: entry) }
        }
        // Temp files of interrupted durable writes.
        for dir in [bundle.url, bundle.currentDirectory, bundle.stateDirectory]
        where fm.fileExists(atPath: dir.path) {
            for entry in try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            where entry.lastPathComponent.hasPrefix(".") && entry.lastPathComponent.contains(".tmp-") {
                try fm.removeItem(at: entry)
            }
        }
    }

    // MARK: - Helpers

    /// Entries of `current/` that a snapshot captures: everything but RAM state and the generation file.
    private func liveEntries() throws -> [URL] {
        try fm.contentsOfDirectory(at: bundle.currentDirectory, includingPropertiesForKeys: nil)
            .filter { !["state", "generation.json"].contains($0.lastPathComponent) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// `fsync`s a file, or every file under a directory.
    private static func flush(_ url: URL) {
        let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil)
        let urls = enumerator.map { Array($0.compactMap { $0 as? URL }) } ?? []
        for item in [url] + urls {
            let fd = open(item.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { continue }
            fsync(fd)
            close(fd)
        }
    }

    private static func allocatedBytes(_ url: URL) -> UInt64 {
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) else {
            return (try? DiskImage.allocatedBytes(url)) ?? 0
        }
        var total = (try? DiskImage.allocatedBytes(url)) ?? 0
        for case let child as URL in enumerator {
            total += UInt64((try? child.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
        }
        return total
    }
}
