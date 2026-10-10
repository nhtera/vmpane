import Darwin
import Foundation

public enum BundleError: Error, Equatable, Sendable {
    case alreadyExists
    case notABundle
    case symlink
    case locked
    /// A path in the config points outside the bundle (`..`, absolute, or through a symlink).
    case unsafePath(String)
}

/// A `.vmpane` bundle on disk. Directories are 0700 and files 0600.
///
/// ```
/// Name.vmpane/  config.json  bundle.lock  icon.png  thumbnail.png
///   current/    generation.json  disk.img  aux/  state/
///   snapshots/<uuid>/   install/   restore.journal   logs/
/// ```
public struct VMBundle: Sendable, Equatable {
    public let url: URL

    public var configURL: URL { url.appendingPathComponent("config.json") }
    public var lockURL: URL { url.appendingPathComponent("bundle.lock") }
    public var currentDirectory: URL { url.appendingPathComponent("current", isDirectory: true) }
    public var generationURL: URL { currentDirectory.appendingPathComponent("generation.json") }
    public var auxDirectory: URL { currentDirectory.appendingPathComponent("aux", isDirectory: true) }
    public var stateDirectory: URL { currentDirectory.appendingPathComponent("state", isDirectory: true) }
    public var snapshotsDirectory: URL { url.appendingPathComponent("snapshots", isDirectory: true) }
    public var installDirectory: URL { url.appendingPathComponent("install", isDirectory: true) }
    public var restoreJournalURL: URL { url.appendingPathComponent("restore.journal") }
    public var logsDirectory: URL { url.appendingPathComponent("logs", isDirectory: true) }

    /// File of a disk entry (`disks[].file` is relative to the bundle). Rejects absolute paths and `..`.
    public func fileURL(relativePath: String) throws -> URL {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/"),
            !components.contains(where: { $0 == ".." || $0 == "." || $0.isEmpty })
        else {
            throw BundleError.unsafePath(relativePath)
        }
        return url.appendingPathComponent(relativePath)
    }

    /// No checks: use `create` or `open`. Internal for error reporting on unreadable paths.
    init(uncheckedURL url: URL) {
        // One canonical form (standardized, directory URL) so bundles compare equal however they were reached.
        self.url = URL(fileURLWithPath: url.standardizedFileURL.path, isDirectory: true)
    }

    /// Creates the bundle directory tree, `config.json` and a first generation. Fails if `url` exists.
    public static func create(at url: URL, config: VMConfigV1) throws -> VMBundle {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) { throw BundleError.alreadyExists }
        let bundle = VMBundle(uncheckedURL: url)
        for dir in [
            bundle.url, bundle.currentDirectory, bundle.auxDirectory, bundle.stateDirectory,
            bundle.snapshotsDirectory, bundle.logsDirectory,
        ] {
            try fm.createDirectory(
                at: dir, withIntermediateDirectories: dir != bundle.url ? false : true,
                attributes: [.posixPermissions: 0o700])
        }
        try Generation().write(to: bundle.generationURL)
        try DurableWrite.write(CanonicalJSON.encode(config), to: bundle.configURL)
        return bundle
    }

    /// Opens an existing bundle. The bundle itself must not be a symlink.
    public static func open(_ url: URL) throws -> VMBundle {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw BundleError.notABundle }
        if (info.st_mode & S_IFMT) == S_IFLNK { throw BundleError.symlink }
        guard (info.st_mode & S_IFMT) == S_IFDIR else { throw BundleError.notABundle }
        let bundle = VMBundle(uncheckedURL: url)
        guard FileManager.default.fileExists(atPath: bundle.configURL.path) else { throw BundleError.notABundle }
        // A bundle from elsewhere must not redirect its parts outside itself.
        for part in [
            bundle.configURL, bundle.currentDirectory, bundle.auxDirectory, bundle.stateDirectory,
            bundle.snapshotsDirectory, bundle.installDirectory, bundle.logsDirectory, bundle.restoreJournalURL,
            bundle.lockURL,
        ] {
            var partInfo = stat()
            if lstat(part.path, &partInfo) == 0, (partInfo.st_mode & S_IFMT) == S_IFLNK { throw BundleError.symlink }
        }
        return bundle
    }

    /// Creates a bundle under a hidden staging name, lets `populate` fill it, then publishes it at `url`
    /// with an exclusive rename. A crash leaves only a hidden `.…partial` directory, never a half-made VM.
    public static func createStaged(at url: URL, config: VMConfigV1, populate: (VMBundle) throws -> Void) throws -> VMBundle {
        let final = VMBundle(uncheckedURL: url)
        if FileManager.default.fileExists(atPath: final.url.path) { throw BundleError.alreadyExists }
        let staging = final.url.deletingLastPathComponent()
            .appendingPathComponent(".\(final.url.lastPathComponent).partial-\(UUID().uuidString)", isDirectory: true)
        let bundle = try create(at: staging, config: config)
        do {
            try populate(bundle)
            guard renamex_np(bundle.url.path, final.url.path, UInt32(RENAME_EXCL)) == 0 else {
                if errno == EEXIST { throw BundleError.alreadyExists }
                throw POSIXError.current()
            }
            try DurableWrite.syncDirectory(final.url.deletingLastPathComponent())
        } catch {
            try? FileManager.default.removeItem(at: bundle.url)
            throw error
        }
        return final
    }

    /// Takes `bundle.lock` without waiting; nil if a helper (or one of its children) holds it.
    public func tryLock() throws -> BundleLock? {
        try FileLock.tryAcquire(lockURL).map { BundleLock(bundle: self, lock: $0) }
    }

    /// `tryLock`, retried for up to `timeout`. Use after reaping a lock holder, and whenever "busy" would be
    /// reported to the user: a process another thread is launching with Foundation's `Process` (which forks
    /// before exec) briefly holds copies of every descriptor, close-on-exec ones included.
    public func tryLock(retryingFor timeout: TimeInterval) throws -> BundleLock? {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let lock = try tryLock() { return lock }
            if Date() >= deadline { return nil }
            usleep(20_000)
        }
    }

    /// Deletes the bundle. Requires its lock, so a running VM cannot be deleted.
    /// Renamed to a hidden name first, so a crash mid-delete never leaves a half-deleted VM in the library.
    public func delete(holding lock: BundleLock) throws {
        precondition(lock.bundle == self, "lock belongs to another bundle")
        let doomed = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).deleting-\(UUID().uuidString)")
        guard rename(url.path, doomed.path) == 0 else { throw POSIXError.current() }
        lock.release()
        try FileManager.default.removeItem(at: doomed)
    }
}

/// Proof that the caller holds a bundle's `bundle.lock`. Operations that write the bundle take one.
public final class BundleLock: Sendable {
    public let bundle: VMBundle
    private let lock: FileLock

    init(bundle: VMBundle, lock: FileLock) {
        self.bundle = bundle
        self.lock = lock
    }

    /// The locked descriptor, to be inherited by child processes that write the disks.
    public var fileDescriptor: Int32 { lock.fileDescriptor }

    public func release() { lock.release() }
}
