import CryptoKit
import Foundation

/// `library.json`: the VMs the user has, by id, path and a bookmark that follows moves.
public struct LibraryIndex: Codable, Equatable, Sendable {
    public static let schemaVersion = 1

    public struct Entry: Codable, Equatable, Sendable {
        public var id: UUID
        public var path: String
        public var bookmark: Data?
    }

    public var schemaVersion: Int
    public var bundles: [Entry]

    public init(bundles: [Entry] = []) {
        schemaVersion = Self.schemaVersion
        self.bundles = bundles
    }
}

/// The VM library: index plus the default VM directory. Index updates are serialised across processes
/// (app, CLI) with `library.lock`.
public struct VMLibrary: Sendable {
    public let paths: VMPanePaths

    public init(paths: VMPanePaths) {
        self.paths = paths
    }

    private var lockURL: URL { paths.root.appendingPathComponent("library.lock") }

    /// A library VM: its bundle and config (nil config when unreadable, e.g. a newer schema).
    public struct Item: Sendable {
        public let id: UUID
        public let bundle: VMBundle
        public let config: VMConfigV1?
        public let error: String?
    }

    /// Two bundles that share an id or a MAC: `duplicate` needs a new identity (see `FullClone`).
    public struct IdentityConflict: Equatable, Sendable {
        public let original: URL
        public let duplicate: URL
    }

    public func readIndex() throws -> LibraryIndex {
        guard FileManager.default.fileExists(atPath: paths.libraryIndex.path) else { return LibraryIndex() }
        let index = try CanonicalJSON.decoder().decode(LibraryIndex.self, from: Data(contentsOf: paths.libraryIndex))
        if index.schemaVersion > LibraryIndex.schemaVersion {
            throw ConfigError.newerSchema(found: index.schemaVersion, supported: LibraryIndex.schemaVersion)
        }
        return index
    }

    /// Read-modify-write of the index under `library.lock`.
    @discardableResult
    public func updateIndex<T>(_ body: (inout LibraryIndex) throws -> T) throws -> T {
        try ensureRoot()
        let lock = try FileLock.acquire(lockURL)
        defer { lock.release() }
        var index = try readIndex()
        let result = try body(&index)
        try DurableWrite.write(CanonicalJSON.encode(index), to: paths.libraryIndex)
        return result
    }

    /// Adds a bundle to the index (or updates its entry). Another VM's entry is never replaced: a bundle
    /// that shares an id or a MAC with an indexed VM gets a new identity first (see `adopt`).
    public func register(_ bundle: VMBundle) throws {
        guard let lock = try bundle.tryLock(retryingFor: 0.5) else {
            throw LibraryOps.VMRunning()  // its helper registers it (helpers adopt on start)
        }
        defer { lock.release() }
        try adopt(holding: lock)
    }

    /// Registers a locked bundle, giving it a new identity first if it duplicates an indexed VM (same id
    /// at another path, or a shared MAC). Returns the (possibly new) config.
    @discardableResult
    public func adopt(holding lock: BundleLock) throws -> (config: VMConfigV1, regenerated: Bool) {
        let bundle = lock.bundle
        return try updateIndex { index in
            var config = try ConfigStore.load(bundle)
            let others = index.bundles.filter { !VMBundle.samePlace($0.path, bundle.url.path) }
            var clash = others.contains { $0.id == config.id }
            if !clash {
                let macs = Set(config.network.map { MachineIdentity.normalizedMAC($0.macAddress) })
                clash = others.contains { entry in
                    guard let other = try? ConfigStore.load(VMBundle(uncheckedURL: URL(fileURLWithPath: entry.path))) else { return false }
                    return !macs.isDisjoint(with: other.network.map { MachineIdentity.normalizedMAC($0.macAddress) })
                }
            }
            if clash { config = try FullClone.regenerateIdentity(holding: lock) }
            index.bundles.removeAll { VMBundle.samePlace($0.path, bundle.url.path) }
            index.bundles.append(.init(id: config.id, path: bundle.url.path, bookmark: try? bundle.url.bookmarkData()))
            return (config, clash)
        }
    }

    /// The listing id of a copy not adopted yet: derived from its path, so it is the same at every listing.
    static func listingID(forCopyAt url: URL) -> UUID {
        let bytes = Array(SHA256.hash(data: Data(url.path.utf8)).prefix(16))
        return NSUUID(uuidBytes: bytes) as UUID
    }

    public func unregister(id: UUID) throws {
        try updateIndex { $0.bundles.removeAll { $0.id == id } }
    }

    /// Resolves each index entry (bookmark first, then the stored path) and adds bundles found in the
    /// default directory that are not indexed yet. Moved bundles get their path updated.
    public func items() throws -> [Item] {
        try ensureRoot()
        var resolved: [(UUID, URL)] = []
        var unindexed: [(UUID, URL)] = []
        try updateIndex { index in
            for i in index.bundles.indices {
                let entry = index.bundles[i]
                var url = URL(fileURLWithPath: entry.path)
                if let bookmark = entry.bookmark {
                    var stale = false
                    if let target = try? URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &stale) {
                        url = target
                        if stale || target.path != entry.path {
                            index.bundles[i].path = target.path
                            index.bundles[i].bookmark = try? target.bookmarkData()
                        }
                    }
                }
                resolved.append((entry.id, url))
            }
            let known = Set(resolved.map { VMBundle(uncheckedURL: $0.1).url.path })
            let indexedIDs = Set(index.bundles.map(\.id))
            let found = (try? FileManager.default.contentsOfDirectory(at: paths.defaultLibrary, includingPropertiesForKeys: nil)) ?? []
            for url in found.sorted(by: { $0.path < $1.path })
            where url.pathExtension == VMPane.bundleExtension && !url.lastPathComponent.hasPrefix(".") {
                guard let bundle = try? VMBundle.open(url), !known.contains(bundle.url.path),
                    let config = try? ConfigStore.load(bundle)
                else { continue }
                if indexedIDs.contains(config.id) {
                    // A copy of an indexed VM (it may still be being copied): indexed only once its helper adopts it
                    // with an identity of its own; listed meanwhile under an id of its own, never the original's.
                    unindexed.append((Self.listingID(forCopyAt: bundle.url), bundle.url))
                    continue
                }
                index.bundles.append(.init(id: config.id, path: bundle.url.path, bookmark: try? bundle.url.bookmarkData()))
                resolved.append((config.id, bundle.url))
            }
        }
        let copies = Set(unindexed.map(\.0))
        return (resolved + unindexed).map { id, url in
            do {
                let bundle = try VMBundle.open(url)
                do {
                    var config = try ConfigStore.load(bundle)
                    // Listed under the name its helper gives it when it adopts the copy.
                    if copies.contains(id) { config.name = FullClone.copyName(of: config.name, at: bundle.url) }
                    return Item(id: id, bundle: bundle, config: config, error: nil)
                } catch {
                    return Item(id: id, bundle: bundle, config: nil, error: Self.problem(error, at: url))
                }
            } catch {
                return Item(id: id, bundle: VMBundle(uncheckedURL: url), config: nil, error: Self.problem(error, at: url))
            }
        }
    }

    /// Pairs of library bundles that share an id or a MAC address. `items` is in library order (indexed
    /// bundles first, newly found ones after), so the later one, e.g. a Finder copy, is the duplicate.
    /// Creation dates are not used: copies can keep the original's.
    public static func identityConflicts(_ items: [Item]) -> [IdentityConflict] {
        var seenIDs: [UUID: URL] = [:]
        var seenMACs: [String: URL] = [:]
        var conflicts: [IdentityConflict] = []
        for item in items {
            guard let config = item.config else { continue }
            let macs = config.network.map { MachineIdentity.normalizedMAC($0.macAddress) }
            let clash = seenIDs[config.id] ?? macs.lazy.compactMap { seenMACs[$0] }.first
            if let original = clash {
                conflicts.append(IdentityConflict(original: original, duplicate: item.bundle.url))
                continue
            }
            seenIDs[config.id] = item.bundle.url
            for mac in macs { seenMACs[mac] = item.bundle.url }
        }
        return conflicts
    }

    private func ensureRoot() throws {
        try paths.ensureRoot()
    }

    /// Why the bundle at `url` cannot be listed or acted on, in words for the library's "Problem" section and alerts.
    public static func problem(_ error: Error, at url: URL) -> String {
        if !FileManager.default.fileExists(atPath: url.path) {
            return "Not found. The VM was moved, renamed or deleted, or it is on a disk that is not connected."
        }
        switch error {
        case BundleError.notABundle: return "This is not a VMPane VM: it has no settings file (config.json)."
        case BundleError.symlink: return "It is reached through a symbolic link, which VMPane does not follow."
        case BundleError.locked: return "Another process is using it."
        case is LibraryOps.VMRunning: return "It is running. Shut it down first."
        case BundleError.unsafePath(let path): return "Its settings point outside the VM (\(path)), so VMPane does not open it."
        case ConfigError.newerSchema: return "It was made by a newer version of VMPane. Update VMPane to open it."
        case is ConfigError, is DecodingError: return "Its settings file (config.json) is damaged."
        default:
            // Cocoa and POSIX errors read well localised; VMPane's own errors describe themselves.
            let domain = (error as NSError).domain
            return [NSCocoaErrorDomain, NSPOSIXErrorDomain].contains(domain) ? error.localizedDescription : String(describing: error)
        }
    }
}
