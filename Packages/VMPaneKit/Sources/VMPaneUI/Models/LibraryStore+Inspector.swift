import Foundation
import VMPaneControl
import VMPaneCore

/// The library's inspector and live thumbnails: a VM's hardware and snapshots straight from its bundle while it is
/// stopped (no helper), through its helper while it runs; each bundle's folder watched for the helper's new picture.
extension LibraryStore {
    /// Bytes the bundle occupies (allocated, so sparse disks count what they use).
    nonisolated static func allocatedBytes(_ url: URL) -> UInt64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) else { return 0 }
        var total: UInt64 = 0
        for case let file as URL in walker {
            guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            total += UInt64(values.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    /// Milliseconds since this process started.
    static func sinceLaunchMs() -> Int {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&name, 4, &info, &size, nil, 0) == 0 else { return -1 }
        let start = info.kp_proc.p_un.__p_starttime
        let started = Double(start.tv_sec) + Double(start.tv_usec) / 1e6
        return Int((Date().timeIntervalSince1970 - started) * 1000)
    }

    struct Measured: Sendable {
        let id: UUID
        let size: UInt64
        let thumbnail: URL?
        let date: Date?
        let suspended: Bool
        let agentClient: String?
        let agentAt: Date?
    }

    /// What `reload` reads of a bundle off the main actor: its size, its last picture, whether it is suspended, and
    /// the agent that last used it.
    nonisolated static func measure(_ id: UUID, _ url: URL) -> Measured {
        let thumbnail = url.appendingPathComponent("thumbnail.png")
        let date = (try? thumbnail.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let agent = AuditLog(url: url.appendingPathComponent("logs/mcp-audit.jsonl")).recent(limit: 1).first
        return Measured(
            id: id, size: allocatedBytes(url), thumbnail: date.map { _ in thumbnail }, date: date,
            suspended: VMBundle.isSuspended(url), agentClient: agent.map { $0.client ?? $0.identity },
            agentAt: agent.flatMap { AuditEntry.date($0.timestamp) })
    }

    /// Picks up a new thumbnail (and agent activity) as soon as the helper writes it.
    func watchFolder(_ id: UUID, _ url: URL) {
        let folder = open(url.path, O_EVTONLY)
        guard folder >= 0 else { return }
        // On the main queue: the handler is this main-actor class's (Swift checks where it runs).
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: folder, eventMask: [.write, .rename], queue: .main)
        source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.refreshThumbnail(id) } }
        source.setCancelHandler { close(folder) }
        source.resume()
        folderWatches[id] = source
    }

    func refreshThumbnail(_ id: UUID) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        let thumbnail = rows[index].bundleURL.appendingPathComponent("thumbnail.png")
        let date = (try? thumbnail.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if date != rows[index].thumbnailDate {
            rows[index].thumbnail = date.map { _ in thumbnail }
            rows[index].thumbnailDate = date
        }
    }

    // MARK: - The inspector

    /// A VM's hardware (stopped: read straight from its bundle).
    public func resources(_ id: UUID) async throws -> StoppedSettings {
        guard let row = row(id) else { throw CocoaError(.fileNoSuchFile) }
        let url = row.bundleURL
        return try await Blocking.run { StoppedSettings(try ConfigStore.load(VMBundle.open(url))) }
    }

    /// Changes a stopped VM's hardware, with no helper.
    public func updateResources(_ id: UUID, _ settings: StoppedSettings) async throws {
        guard let row = row(id), !row.isRunning else { throw LibraryOps.VMRunning() }
        let ops = LibraryOps(library: library, identity: .ui)
        let bundle = try VMBundle.open(row.bundleURL)
        try await releaseHelper(of: row) { _ = try ops.updateStopped(bundle) { $0 = settings } }
    }

    /// The VM's snapshots: through its helper while it runs, else straight on its bundle.
    public func snapshotsModel(_ id: UUID) -> SnapshotsModel? {
        guard let row = row(id) else { return nil }
        if row.state != nil { return SnapshotsModel(channel: LinkChannel(links: links, vm: id)) }
        guard let bundle = try? VMBundle.open(row.bundleURL) else { return nil }
        return SnapshotsModel(stopped: bundle, ops: LibraryOps(library: library, identity: .ui))
    }

    /// What the guest tools say about the running guest: its OS version and theirs.
    public func guestInfo(_ id: UUID) async -> (osVersion: String?, toolsVersion: String?) {
        guard row(id)?.isRunning == true, let status = try? await links.call(id, ControlMethod.agentStatus.rawValue, params: nil),
            status["connected"] == true
        else { return (nil, nil) }
        return (status["osVersion"]?.stringValue, status["version"]?.stringValue)
    }

}

/// A running VM's helper reached through `LiveVMLink`, as a `HelperChannel` (one connection per call).
struct LinkChannel: HelperChannel {
    let links: LiveVMLink
    let vm: UUID

    func call(_ method: String, params: JSONValue?, timeout: Duration) async throws -> JSONValue {
        try await links.call(vm, method, params: params)
    }

    var notifications: AsyncStream<RPCRequest> { AsyncStream { $0.finish() } }
}
