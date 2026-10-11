import Foundation
import OSLog
import Observation
import VMPaneControl
import VMPaneCore
import VMPaneHost

/// The VM library as the app shows it: every bundle of the library with its live state, kept current from the
/// helpers' `vm.stateChanged` events (a VM without a helper is "not running"). Stopped-VM operations go
/// through Core's `LibraryOps`; running VMs through their helper.
@MainActor
@Observable
public final class LibraryStore {
    public struct Row: Identifiable, Equatable, Sendable {
        public let id: UUID
        public var name: String
        public var os: GuestOS?
        public var bundleURL: URL
        /// nil: no helper runs it.
        public var state: VMRunState?
        /// Space the bundle takes on disk (sparse disks count what they use); nil until measured.
        public var diskBytes: UInt64?
        /// Why the bundle cannot be read, if it cannot.
        public var error: String?
        /// The helper's last picture of the guest (`thumbnail.png`), and when it was taken.
        public var thumbnail: URL?
        public var thumbnailDate: Date?

        public var isRunning: Bool { state.map { ![.stopped, .error].contains($0) } ?? false }
    }

    public enum Action: Sendable {
        case start(headless: Bool)
        case stop(force: Bool)
        case pause, resume, suspend, showWindow
    }

    public private(set) var rows: [Row] = []
    public var selection: UUID?
    /// The last failed action, for an alert.
    public var lastError: String?

    @ObservationIgnored private let library: VMLibrary
    @ObservationIgnored private let links: LiveVMLink
    @ObservationIgnored private let launch: @Sendable (VMBundle, Bool) async throws -> Void
    @ObservationIgnored private var watches: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var listedOnce = false
    @ObservationIgnored private var watchTokens: [UUID: UUID] = [:]

    /// `launch(bundle, headless)` starts a VM's helper (the app's supervisor, via the runtime copy).
    public init(library: VMLibrary, links: LiveVMLink, launch: @escaping @Sendable (VMBundle, Bool) async throws -> Void) {
        self.library = library
        self.links = links
        self.launch = launch
    }

    public func row(_ id: UUID) -> Row? { rows.first { $0.id == id } }

    /// A copy of a stopped VM, as a new machine, under `name`.
    public func clone(_ id: UUID, name: String) async {
        guard let row = row(id), !row.isRunning else { return }
        let ops = LibraryOps(library: library, identity: .ui)
        do {
            let bundle = try VMBundle.open(row.bundleURL)
            _ = try await Blocking.run { try ops.clone(bundle, name: name) }
            await reload()
        } catch {
            lastError = "Cannot clone \(row.name): \(error)"
        }
    }

    /// Deletes a stopped VM (its bundle, disks and snapshots).
    public func delete(_ id: UUID) async {
        guard let row = row(id), !row.isRunning else { return }
        let ops = LibraryOps(library: library, identity: .ui)
        do {
            let bundle = try VMBundle.open(row.bundleURL)
            try await Blocking.run { try ops.delete(bundle) }
            if selection == id { selection = nil }
            await reload()
        } catch {
            lastError = "Cannot delete \(row.name): \(error)"
        }
    }

    /// Adds VM bundles opened or dropped from elsewhere (Finder, another Mac) and selects the last one. A bundle
    /// that duplicates a listed VM gets its own identity; its config is checked as any other bundle's.
    public func importBundles(_ urls: [URL]) async {
        let ops = LibraryOps(library: library, identity: .ui)
        var last: URL?
        for url in urls where url.pathExtension == VMPane.bundleExtension {
            do {
                last = try await Blocking.run { try ops.importBundle(at: url).url }
            } catch {
                lastError = "Cannot add \(url.lastPathComponent): \(error)"
            }
        }
        await reload()
        if let last, let row = rows.first(where: { $0.bundleURL.standardizedFileURL == last.standardizedFileURL }) {
            selection = row.id
        }
    }

    /// A new VM from a Parallels `.pvm` (its boot disk converted with `qemu-img`), listed and selected; not started.
    public func importParallels(
        _ pvm: URL, name: String, os: GuestOS, qemuImg: URL, progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let ops = LibraryOps(library: library, identity: .ui)
        let bundle = try await ParallelsImporter(qemuImg: qemuImg).importVM(pvm, name: name, os: os, ops: ops, progress: progress)
        await reload()
        selection = rows.first { $0.bundleURL.standardizedFileURL == bundle.url.standardizedFileURL }?.id
    }

    /// Creates VMs in this library (the wizard).
    public func makeCreator() -> VMCreator {
        VMCreator(ops: LibraryOps(library: library, identity: .ui))
    }

    /// A VM the wizard just made: listed, selected, and started (which begins its install).
    public func didCreate(_ bundle: VMBundle) async {
        await reload()
        guard let id = rows.first(where: { $0.bundleURL.standardizedFileURL == bundle.url.standardizedFileURL })?.id else { return }
        selection = id
        await perform(.start(headless: false), on: id)
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

    /// Re-reads the library (bundles added, moved or removed), attaches to helpers that started since, and
    /// measures disk usage in the background.
    public func reload() async {
        let library = library
        let items: [VMLibrary.Item]
        do {
            items = try await Blocking.run { try library.items() }
        } catch {
            lastError = "Cannot read the library: \(error)"
            return
        }
        let known = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        if !listedOnce {
            listedOnce = true
            // The perf itest reads the app's launch time here.
            Logger(subsystem: VMPane.SigningIdentifier.app, category: "library").notice(
                "library listed \(items.count, privacy: .public) VMs \(Self.sinceLaunchMs(), privacy: .public) ms after launch")
        }
        rows = items.map { item in
            Row(
                id: item.id, name: item.config?.name ?? item.bundle.url.deletingPathExtension().lastPathComponent,
                os: item.config?.os, bundleURL: item.bundle.url, state: known[item.id]?.state,
                diskBytes: known[item.id]?.diskBytes, error: item.error)
        }
        for id in Set(watches.keys).subtracting(rows.map(\.id)) {
            watches.removeValue(forKey: id)?.cancel()
        }
        for row in rows where watches[row.id] == nil {
            attach(row.id)
        }
        let urls = rows.map { ($0.id, $0.bundleURL) }
        let measured = await Blocking.run {
            urls.map { id, url in
                let thumbnail = url.appendingPathComponent("thumbnail.png")
                let date = (try? thumbnail.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                return (id, Self.allocatedBytes(url), date.map { _ in thumbnail }, date)
            }
        }
        for (id, size, thumbnail, date) in measured {
            guard let index = rows.firstIndex(where: { $0.id == id }) else { continue }
            rows[index].diskBytes = size
            rows[index].thumbnail = thumbnail
            rows[index].thumbnailDate = date
        }
    }

    /// Follows the VM's helper while it runs.
    private func attach(_ id: UUID) {
        let links = links
        let token = UUID()
        watchTokens[id] = token
        watches[id] = Task { [weak self] in
            if let states = await links.watch(id) {
                for await state in states {
                    self?.setState(state, for: id)
                }
                self?.setState(nil, for: id)
            }
            // Only this watch's own entry: a newer one may have replaced it meanwhile.
            if self?.watchTokens[id] == token {
                self?.watches[id] = nil
                self?.watchTokens[id] = nil
            }
        }
    }

    private func setState(_ state: VMRunState?, for id: UUID) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[index].state = state
    }

    public func perform(_ action: Action, on id: UUID) async {
        guard let row = row(id) else { return }
        do {
            switch action {
            case .start(let headless):
                if row.state == nil {
                    let bundle = try VMBundle.open(row.bundleURL)
                    try await launch(bundle, headless)
                    try await attachWhenUp(id)
                }
                _ = try await links.call(id, ControlMethod.vmStart.rawValue, params: ["headless": .bool(headless)])
            case .stop(let force):
                _ = try await links.call(id, ControlMethod.vmStop.rawValue, params: ["mode": force ? "force" : "graceful"])
            case .pause: _ = try await links.call(id, ControlMethod.vmPause.rawValue, params: nil)
            case .resume: _ = try await links.call(id, ControlMethod.vmResume.rawValue, params: nil)
            case .suspend: _ = try await links.call(id, ControlMethod.vmSuspend.rawValue, params: nil)
            case .showWindow: _ = try await links.call(id, ControlMethod.vmDisplayShow.rawValue, params: nil)
            }
        } catch let error as RPCError {
            lastError = error.message
        } catch {
            lastError = String(describing: error)
        }
    }

    /// A launched helper takes a moment to listen: attach once it does (up to 10 s).
    private func attachWhenUp(_ id: UUID) async throws {
        for _ in 0..<50 {
            if watches[id] == nil { attach(id) }
            try await Task.sleep(for: .milliseconds(200))
            if row(id)?.state != nil { return }
        }
        throw RPCError(.backendUnavailable, "the VM's helper did not start")
    }

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
}
