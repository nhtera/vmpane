import Foundation
import Observation
import VMPaneControl
import VMPaneCore

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

    /// `launch(bundle, headless)` starts a VM's helper (the app's supervisor, via the runtime copy).
    public init(library: VMLibrary, links: LiveVMLink, launch: @escaping @Sendable (VMBundle, Bool) async throws -> Void) {
        self.library = library
        self.links = links
        self.launch = launch
    }

    public func row(_ id: UUID) -> Row? { rows.first { $0.id == id } }

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
        let sizes = await Blocking.run { urls.map { ($0.0, Self.allocatedBytes($0.1)) } }
        for (id, size) in sizes {
            if let index = rows.firstIndex(where: { $0.id == id }) { rows[index].diskBytes = size }
        }
    }

    /// Follows the VM's helper while it runs.
    private func attach(_ id: UUID) {
        let links = links
        watches[id] = Task { [weak self] in
            guard let states = await links.watch(id) else {
                self?.watches[id] = nil
                return
            }
            for await state in states {
                self?.setState(state, for: id)
            }
            self?.setState(nil, for: id)
            self?.watches[id] = nil
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
