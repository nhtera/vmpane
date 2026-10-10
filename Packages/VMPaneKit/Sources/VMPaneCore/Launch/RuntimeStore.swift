import Foundation

/// Versioned copies of the helper app under `runtime/<version>/`. Helpers run from a copy, so an app
/// update (Sparkle replacing VMPane.app) never pulls the binary out from under a running VM.
public struct RuntimeStore: Sendable {
    public let paths: VMPanePaths

    public init(paths: VMPanePaths) {
        self.paths = paths
    }

    /// Versions younger than this are never garbage-collected: a helper may be starting from one before
    /// it has written its pid file.
    public static let minimumAge: TimeInterval = 10 * 60

    /// Returns `runtime/<version>/<helper app name>`, creating it as an APFS clone (or a synced copy) of
    /// `source`. Serialised per version across processes.
    public func ensure(version: String, helperApp source: URL) throws -> URL {
        let fm = FileManager.default
        let directory = paths.runtime(version: version)
        let target = directory.appendingPathComponent(source.lastPathComponent, isDirectory: true)
        try fm.createDirectory(at: paths.runtimeDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let lock = try FileLock.acquire(paths.runtimeDirectory.appendingPathComponent(".\(version).lock"))
        defer { lock.release() }
        if fm.fileExists(atPath: target.path) { return target }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let partial = directory.appendingPathComponent(".\(source.lastPathComponent).partial-\(UUID().uuidString)", isDirectory: true)
        do {
            do {
                try CloneFile.clone(source, to: partial)
            } catch CloneError.unsupported {
                try fm.copyItem(at: source, to: partial)
            }
            try DurableWrite.syncTree(partial)
            try fm.moveItem(at: partial, to: target)
            try DurableWrite.syncDirectory(directory)
        } catch {
            try? fm.removeItem(at: partial)
            throw error
        }
        return target
    }

    /// Removes runtime versions that are not `keep`, not used by a live helper, and older than `minimumAge`.
    public func garbageCollect(keep: Set<String>, now: Date = Date()) throws {
        let inUse = Set(LaunchCoordinator.liveHelpers(paths: paths).map(\.runtimeVersion)).union(keep)
        let fm = FileManager.default
        let versions =
            (try? fm.contentsOfDirectory(at: paths.runtimeDirectory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for version in versions where !version.lastPathComponent.hasPrefix(".") && !inUse.contains(version.lastPathComponent) {
            let modified = (try? version.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? now
            guard now.timeIntervalSince(modified) >= Self.minimumAge else { continue }
            try fm.removeItem(at: version)
        }
    }
}
