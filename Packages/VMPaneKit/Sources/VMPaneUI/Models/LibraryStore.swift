import Foundation
import OSLog
import Observation
import SwiftUI
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
        /// Stopped with its RAM state saved (a start resumes it).
        public var suspended = false
        /// Space the bundle takes on disk (sparse disks count what they use); nil until measured.
        public var diskBytes: UInt64?
        /// Why the bundle cannot be read, if it cannot.
        public var error: String?
        /// The helper's last picture of the guest (`thumbnail.png`), and when it was taken.
        public var thumbnail: URL?
        public var thumbnailDate: Date?
        /// The AI agent that last used the VM (its audit log), and when.
        public var agentClient: String?
        public var agentLastAt: Date?
        /// Its processors and memory, and the level AI agents have (its config; nil when it cannot be read).
        public var cpuCount: Int?
        public var memoryMiB: Int?
        public var policy: PolicyLevel?
        /// Its helper runs on another runtime than this app's (started before an update): a restart takes the update.
        public var outdatedRuntime = false
        /// What its running helper says agents are doing (nil: no helper, or an older one).
        public var agentActing: Bool?
        /// Its install's stage, from its helper (Windows Setup, a cloud image's first boot, a macOS install).
        public var install: HelperViewModel.InstallProgress?

        /// An agent acts on it (its helper says so), else used it within the last minute (its audit log).
        public var agentActive: Bool { agentActing ?? agentLastAt.map { -$0.timeIntervalSinceNow < 60 } ?? false }

        public var isRunning: Bool { state.map { ![.stopped, .error].contains($0) } ?? false }
        /// Listed, but its bundle is no longer on disk (moved, deleted, on a disk not connected).
        public var isMissing: Bool { error != nil && !FileManager.default.fileExists(atPath: bundleURL.path) }
    }

    public enum Action: Sendable {
        case start(headless: Bool)
        case stop(force: Bool)
        case pause, resume, suspend, showWindow
    }

    public internal(set) var rows: [Row] = []
    public var selection: UUID?
    /// The last failed action, for an alert.
    public var lastError: String?
    /// A Parallels VM opened from Finder, for the library window's import sheet.
    public var parallelsToImport: URL?
    /// An installer (.iso, .ipsw) opened with VMPane: the library window offers a new VM from it.
    public var installerToUse: URL?
    /// VMs being created in the background (`LibraryStore+Create`).
    public internal(set) var creations: [Creation] = []
    @ObservationIgnored var creationRequests: [UUID: VMCreator.Request] = [:]
    @ObservationIgnored var creationTasks: [UUID: Task<Void, Never>] = [:]

    /// Asks before a VM starts on a Mac low on memory; nil: starts without asking.
    @ObservationIgnored public var lowMemoryGuard: LowMemoryGuard?
    /// The runtime this app launches helpers from now (`RuntimeStore.version`); nil: a live helper is always reused.
    @ObservationIgnored public var currentRuntime: @Sendable () -> String? = { nil }
    @ObservationIgnored let library: VMLibrary
    @ObservationIgnored let links: LiveVMLink
    @ObservationIgnored private let launch: @Sendable (VMBundle, Bool) async throws -> Void
    @ObservationIgnored private var watches: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var listedOnce = false
    @ObservationIgnored private var watchTokens: [UUID: UUID] = [:]
    /// One look again per VM at its agents' activity once acting has run out (`setActivity`).
    @ObservationIgnored fileprivate var activityRefreshes: [UUID: Task<Void, Never>] = [:]
    /// Each bundle's folder, for its `thumbnail.png` (written atomically: a rename in the folder).
    @ObservationIgnored var folderWatches: [UUID: DispatchSourceFileSystemObject] = [:]

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
            try await releaseHelper(of: row) { _ = try ops.clone(bundle, name: name) }
            await reload()
        } catch {
            lastError = "Cannot clone \(row.name): \(VMLibrary.problem(error, at: row.bundleURL))"
        }
    }

    /// Deletes a stopped VM (its bundle, disks and snapshots). One already gone from disk is taken off the list.
    public func delete(_ id: UUID) async {
        guard let row = row(id), !row.isRunning else { return }
        if row.isMissing {
            await removeFromLibrary(id)
            return
        }
        let ops = LibraryOps(library: library, identity: .ui)
        do {
            let bundle = try VMBundle.open(row.bundleURL)
            try await releaseHelper(of: row) { try ops.delete(bundle) }
            if selection == id { selection = nil }
            await reload()
        } catch {
            lastError = "Cannot delete \(row.name): \(VMLibrary.problem(error, at: row.bundleURL))"
        }
    }

    /// Runs `work`, which needs the stopped VM's bundle to itself. A stopped VM's helper keeps running (its window
    /// and Dock tile stay) and holds the bundle, so it is asked to quit first; `work` is tried until it lets go.
    func releaseHelper(of row: Row, _ work: @escaping @Sendable () throws -> Void) async throws {
        if row.state != nil {
            _ = try? await links.call(row.id, ControlMethod.helperShutdown.rawValue, params: nil)
        }
        let deadline = ContinuousClock.now + .seconds(15)
        while true {
            do {
                return try await Blocking.run(work)
            } catch is LibraryOps.VMRunning where row.state != nil && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    /// Takes a VM the library cannot open (moved, deleted, damaged) off the list; nothing on disk changes.
    public func removeFromLibrary(_ id: UUID) async {
        guard let row = row(id), row.error != nil, !row.isRunning else { return }
        let library = library
        do {
            try await Blocking.run { try library.unregister(id: id) }
            if selection == id { selection = nil }
            await reload()
        } catch {
            lastError = "Cannot remove \(row.name) from the library: \(error.localizedDescription)"
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
                lastError = "Cannot add \(url.lastPathComponent): \(VMLibrary.problem(error, at: url))"
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

    /// Re-reads the library (bundles added, moved or removed), attaches to helpers that started since, and
    /// measures disk usage in the background.
    public func reload() async {
        let library = library
        let items: [VMLibrary.Item]
        let unfinished: Set<UUID>
        do {
            items = try await Blocking.run { try library.items() }
            unfinished = await Blocking.run { Set(items.filter(\.bundle.isUnfinished).map(\.id)) }
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
        // A VM a create here is still preparing is listed once it is finished (`creations` shows it meanwhile).
        rows = items.filter { !(unfinished.contains($0.id) && beingCreated($0)) }.map { item in
            var row = Row(
                id: item.id, name: item.config?.name ?? item.bundle.url.deletingPathExtension().lastPathComponent,
                os: item.config?.os, bundleURL: item.bundle.url, state: known[item.id]?.state,
                diskBytes: known[item.id]?.diskBytes, error: item.error ?? unfinishedProblem(item, unfinished))
            (row.cpuCount, row.memoryMiB, row.policy) = (item.config?.cpu.count, item.config?.memory.mib, item.config?.mcp.policy)
            // What its helper said (it says it again only when it changes), and its runtime.
            (row.agentActing, row.install) = (known[item.id]?.agentActing, known[item.id]?.install)
            row.outdatedRuntime = known[item.id]?.outdatedRuntime ?? false
            return row
        }
        for id in Set(watches.keys).subtracting(rows.map(\.id)) {
            watches.removeValue(forKey: id)?.cancel()
        }
        for id in Set(folderWatches.keys).subtracting(rows.map(\.id)) {
            folderWatches.removeValue(forKey: id)?.cancel()
        }
        for row in rows where watches[row.id] == nil {
            attach(row.id)
        }
        for row in rows where folderWatches[row.id] == nil {
            watchFolder(row.id, row.bundleURL)
        }
        let urls = rows.map { ($0.id, $0.bundleURL) }
        let measured = await Blocking.run { urls.map(Self.measure) }
        for item in measured {
            guard let index = rows.firstIndex(where: { $0.id == item.id }) else { continue }
            rows[index].suspended = item.suspended
            rows[index].diskBytes = item.size
            rows[index].thumbnail = item.thumbnail
            rows[index].thumbnailDate = item.date
            rows[index].agentClient = item.agentClient?.replacingOccurrences(of: " (claimed)", with: "")
            rows[index].agentLastAt = item.agentAt
        }
    }

    /// Follows the VM's helper while it runs.
    private func attach(_ id: UUID) {
        let links = links
        let token = UUID()
        watchTokens[id] = token
        watches[id] = Task { [weak self] in
            if let events = await links.watch(id) {
                await self?.noteRuntime(of: id)
                for await event in events {
                    switch event {
                    case .state(let state): self?.setState(state, for: id)
                    case .activity(let json): self?.setActivity(AgentActivity(json), for: id)
                    case .install(let json): self?.setInstall(json, for: id)
                    }
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
        if state == nil { (rows[index].agentActing, rows[index].install, rows[index].outdatedRuntime) = (nil, nil, false) }
        if state == nil || state == .stopped { rows[index].suspended = VMBundle.isSuspended(rows[index].bundleURL) }
    }

    public func perform(_ action: Action, on id: UUID) async {
        guard let row = row(id) else { return }
        do {
            switch action {
            case .start(let headless):
                if let lowMemoryGuard, !row.isRunning, !(await hasMemoryToStart(row, lowMemoryGuard)) { return }
                var id = id
                if try await needsHelperLaunch(id) {
                    let bundle = try VMBundle.open(row.bundleURL)
                    try await launch(bundle, headless)
                    id = try await attachWhenUp(id, bundle: bundle.url)
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

    /// A launched helper takes a moment to listen: attach once it does (up to 10 s). Returns the VM's id, which is
    /// new when its helper found it to be a copy (e.g. duplicated in Finder): the row is then found again by its bundle.
    private func attachWhenUp(_ id: UUID, bundle: URL) async throws -> UUID {
        var id = id
        for attempt in 1...50 {
            if watches[id] == nil { attach(id) }
            try await Task.sleep(for: .milliseconds(200))
            if row(id)?.state != nil { return id }
            guard attempt % 5 == 0 else { continue }
            await reload()
            if let found = rows.first(where: { VMBundle.samePlace($0.bundleURL.path, bundle.path) })?.id, found != id {
                if selection == id { selection = found }
                id = found
            }
        }
        throw RPCError(.backendUnavailable, "the VM's helper did not start")
    }
}

extension LibraryStore {
    /// Whether to start `row`: its memory fits in what the Mac has, or the person said to go ahead.
    fileprivate func hasMemoryToStart(_ row: Row, _ lowMemoryGuard: LowMemoryGuard) async -> Bool {
        let url = row.bundleURL
        let mib = await Blocking.run { try? ConfigStore.load(VMBundle.open(url)).memory.mib }
        guard let mib else { return true }
        return await lowMemoryGuard.allows(name: row.name, guestMiB: mib)
    }

    fileprivate func setActivity(_ activity: AgentActivity, for id: UUID) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        if rows[index].agentActing != activity.acting { rows[index].agentActing = activity.acting }
        if let client = activity.client, rows[index].agentClient != client { rows[index].agentClient = client }
        // The helper says nothing when an agent goes quiet: look again once the acting window has passed (one look per
        // VM, moved on by each notification).
        activityRefreshes[id]?.cancel()
        activityRefreshes[id] = nil
        guard activity.acting else { return }
        let links = links
        activityRefreshes[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(11))
            guard !Task.isCancelled, let json = try? await links.call(id, ControlMethod.vmAgentActivity.rawValue, params: nil),
                !Task.isCancelled
            else { return }
            self?.setActivity(AgentActivity(json), for: id)
        }
    }

    /// A bundle a quit left half made (`VMBundle.isUnfinished`; one a create here is making is not listed).
    fileprivate func unfinishedProblem(_ item: VMLibrary.Item, _ unfinished: Set<UUID>) -> String? {
        unfinished.contains(item.id) ? "VMPane stopped before this VM was finished. Delete it, then create it again." : nil
    }

    /// Whether a create here makes `item`: its bundle, or (before the create has said which) its name.
    fileprivate func beingCreated(_ item: VMLibrary.Item) -> Bool {
        creations.contains { creation in
            guard creation.failure == nil else { return false }
            if let bundle = creation.bundle { return bundle.standardizedFileURL == item.bundle.url.standardizedFileURL }
            return creation.name == item.config?.name
        }
    }

    fileprivate func setInstall(_ json: JSONValue, for id: UUID) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        let install = HelperViewModel.InstallProgress(
            phase: json["phase"]?.stringValue ?? "install", percent: Int(json["percent"]?.intValue ?? 0),
            message: json["message"]?.stringValue ?? "")
        if install.message != rows[index].install?.message, !install.message.isEmpty {
            AccessibilityNotification.Announcement("\(rows[index].name): \(install.message)").post()
        }
        rows[index].install = install
    }
}
