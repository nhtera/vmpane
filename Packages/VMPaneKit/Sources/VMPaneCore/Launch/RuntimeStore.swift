import CryptoKit
import Foundation

/// Versioned copies of the helper app (and the QEMU it runs) under `runtime/<version>/`. Helpers run from a
/// copy, so an app update (Sparkle replacing VMPane.app) never pulls a binary out from under a running VM.
public struct RuntimeStore: Sendable {
    public let paths: VMPanePaths

    public init(paths: VMPanePaths) {
        self.paths = paths
    }

    /// Versions younger than this are never garbage-collected: a helper may be starting from one before
    /// it has written its pid file.
    public static let minimumAge: TimeInterval = 10 * 60

    /// Something copied into `runtime/<version>/`: `source` lands at `path` (relative, e.g. `qemu/bin`).
    public struct Item: Sendable, Equatable {
        public var source: URL
        public var path: String

        public init(source: URL, path: String) {
            self.source = source
            self.path = path
        }
    }

    /// The `runtime/` directory name for `app`: its version, plus the identity of its QEMU bundle (`-q…`), of its
    /// Linux and macOS guest tools (`-t…`, `-m…`) when it has them, and of the helper's code (`-h…`), so a rebuild
    /// under the same app version (every Debug build, a re-spun release) gets a fresh copy.
    public static func version(app: URL, appVersion: String) -> String {
        let resources = app.appendingPathComponent("Contents/Resources", isDirectory: true)
        var version = appVersion
        let manifests = [("q", "qemu/MANIFEST.json"), ("t", "GuestTools/linux/SHA256SUMS"), ("m", "GuestTools/macos/SHA256SUMS")]
        for (tag, manifest) in manifests {
            guard let data = try? Data(contentsOf: resources.appendingPathComponent(manifest)) else { continue }
            version += "-\(tag)" + shortHash(data)
        }
        if let code = helperCodeStamp(app: app) { version += "-h" + shortHash(Data(code.utf8)) }
        return version
    }

    /// The helper's executables (`VMPaneVM.app/Contents/MacOS`: the binary and, in Debug builds, its debug dylib)
    /// by name, size and modification date: cheap to read at every launch, and changed by any rebuild.
    static func helperCodeStamp(app: URL) -> String? {
        let code = app.appendingPathComponent("Contents/Helpers/VMPaneVM.app/Contents/MacOS", isDirectory: true)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: code.path), !names.isEmpty else { return nil }
        return names.sorted().map { name in
            let attributes = (try? FileManager.default.attributesOfItem(atPath: code.appendingPathComponent(name).path)) ?? [:]
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            return "\(name):\(size):\(modified)"
        }.joined(separator: "\n")
    }

    private static func shortHash(_ data: Data) -> String {
        SHA256.hash(data: data).prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    /// The runtime version a helper runs from (`runtime/<version>/VMPaneVM.app`), or nil when it does not run
    /// from a runtime copy (started from the app bundle during development).
    public func version(ofHelperAt helper: URL) -> String? {
        let parent = helper.standardizedFileURL.deletingLastPathComponent()
        guard parent.deletingLastPathComponent().path == paths.runtimeDirectory.standardizedFileURL.path else { return nil }
        return parent.lastPathComponent
    }

    /// What a helper runs, from the app bundle: the helper app, QEMU (`qemu/bin`, `qemu/lib` from
    /// `Contents/Helpers/qemu`, `qemu/share` from `Contents/Resources/qemu/share`) and the guest tools
    /// (`GuestTools` from `Contents/Resources/GuestTools`) when the app has them.
    public static func helperItems(app: URL) -> [Item] {
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        let qemu = contents.appendingPathComponent("Helpers/qemu", isDirectory: true)
        let candidates = [
            Item(source: contents.appendingPathComponent("Helpers/VMPaneVM.app", isDirectory: true), path: "VMPaneVM.app"),
            Item(source: qemu.appendingPathComponent("bin", isDirectory: true), path: "qemu/bin"),
            Item(source: qemu.appendingPathComponent("lib", isDirectory: true), path: "qemu/lib"),
            Item(source: contents.appendingPathComponent("Resources/qemu/share", isDirectory: true), path: "qemu/share"),
            Item(source: contents.appendingPathComponent("Resources/GuestTools", isDirectory: true), path: "GuestTools"),
        ]
        return candidates.enumerated().filter { index, item in
            index == 0 || FileManager.default.fileExists(atPath: item.source.path)
        }.map(\.element)
    }

    /// Returns `runtime/<version>/<helper app name>`, creating it as an APFS clone (or a synced copy) of
    /// `source`. Serialised per version across processes.
    public func ensure(version: String, helperApp source: URL) throws -> URL {
        try ensure(version: version, items: [Item(source: source, path: source.lastPathComponent)])
            .appendingPathComponent(source.lastPathComponent, isDirectory: true)
    }

    /// Returns `runtime/<version>`, with each item cloned (or copied and synced) into it if it is not
    /// there yet. Each item appears atomically; all of them are serialised per version across processes.
    @discardableResult
    public func ensure(version: String, items: [Item]) throws -> URL {
        let fm = FileManager.default
        let directory = paths.runtime(version: version)
        try fm.createDirectory(at: paths.runtimeDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let lock = try FileLock.acquire(paths.runtimeDirectory.appendingPathComponent(".\(version).lock"))
        defer { lock.release() }
        for item in items {
            try install(item, in: directory)
        }
        return directory
    }

    private func install(_ item: Item, in directory: URL) throws {
        let fm = FileManager.default
        let target = directory.appendingPathComponent(item.path)
        if fm.fileExists(atPath: target.path) { return }
        let parent = target.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let partial = parent.appendingPathComponent(".\(target.lastPathComponent).partial-\(UUID().uuidString)", isDirectory: true)
        do {
            do {
                try CloneFile.clone(item.source, to: partial)
            } catch CloneError.unsupported {
                try fm.copyItem(at: item.source, to: partial)
            }
            try DurableWrite.syncTree(partial)
            try fm.moveItem(at: partial, to: target)
            try DurableWrite.syncDirectory(parent)
        } catch {
            try? fm.removeItem(at: partial)
            throw error
        }
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
