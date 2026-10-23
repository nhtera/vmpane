import SwiftUI
import VMPaneCore
import VMPaneUI

/// The selected VM in detail: what it is and its state, a problem with its fix, its system, its hardware (changed on
/// a stopped VM with no helper), its snapshots and what AI agents did with it, and the actions for its state.
struct VMInspector: View {
    enum Section: String, CaseIterable, Identifiable {
        case system = "System"
        case resources = "Resources"
        case snapshots = "Snapshots"
        case activity = "Activity"

        var id: String { rawValue }
    }

    let store: LibraryStore
    let row: LibraryStore.Row
    @Binding var section: Section

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    SystemTile(row.system, size: 44)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(row.name).font(.title3.bold()).lineLimit(2)
                        StateDot(row.state, suspended: row.suspended)
                    }
                }
                .accessibilityElement(children: .combine)
                if let error = row.error {
                    ProblemBanner(store: store, row: row, message: error) { section = $0 }
                }
                Picker("Section", selection: $section) {
                    ForEach(Section.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            .padding(12)
            Divider()
            switch section {
            case .system: SystemSection(store: store, row: row)
            case .resources: ResourcesSection(store: store, row: row)
            case .snapshots: SnapshotsSection(store: store, row: row)
            case .activity: Form { AgentActivityView(bundle: row.bundleURL) }.formStyle(.grouped)
            }
            Divider()
            InspectorActions(store: store, row: row).padding(12)
        }
        .inspectorColumnWidth(min: 280, ideal: 300, max: 420)
    }
}

/// What the VM is: system, guest tools, where it is.
private struct SystemSection: View {
    let store: LibraryStore
    let row: LibraryStore.Row
    @State private var guest: (osVersion: String?, toolsVersion: String?) = (nil, nil)

    var body: some View {
        Form {
            LabeledContent("System", value: row.systemName)
            LabeledContent("Version", value: guest.osVersion ?? (row.isRunning ? "—" : "Start it to read"))
            LabeledContent("Guest tools", value: guest.toolsVersion ?? (row.isRunning ? "Not running" : "—"))
            LabeledContent("State") { StateDot(row.state, suspended: row.suspended) }
            LabeledContent("On disk") { ByteSizeText(row.diskBytes) }
            LabeledContent("Location") {
                Text(row.bundleURL.path).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        .task(id: row.state) { guest = await store.guestInfo(row.id) }
    }
}

/// The actions for the VM's state, as capsules: the main one (Show Window, or Start / Resume; Return), Shut Down
/// while it runs, Copy Password for a password VMPane keeps, and the rest in a menu.
private struct InspectorActions: View {
    let store: LibraryStore
    let row: LibraryStore.Row
    @State private var hasPassword = false

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if row.isRunning {
                    Button("Show Window", systemImage: "macwindow") { act(.showWindow) }
                        .keyboardShortcut(.return, modifiers: [])
                        .vmCapsule(prominent: true, large: false)
                    Button("Shut Down", systemImage: "power") { act(.stop(force: false)) }
                        .keyboardShortcut(".", modifiers: .command)
                        .vmCapsule(large: false)
                } else {
                    Button(row.suspended ? "Resume" : "Start", systemImage: "play.fill") { act(.start(headless: false)) }
                        .keyboardShortcut(.return, modifiers: [])
                        .vmCapsule(prominent: true, large: false)
                        .disabled(row.error != nil)
                }
            }
            .labelStyle(.titleOnly)
            if hasPassword {
                Button("Copy Password", systemImage: "key") { copyPassword() }
                    .labelStyle(.iconOnly)
                    .vmCapsule(large: false)
                    .help("Copy the guest account's password VMPane keeps for you; the clipboard forgets it after a minute")
            }
            Spacer(minLength: 0)
            Menu {
                VMActionMenu(store: store, row: row)
            } label: {
                Label("More", systemImage: "ellipsis")
            }
            .labelStyle(.iconOnly)
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .fixedSize()
            .vmCapsule(large: false)
            .help("More actions for this VM")
        }
        .task(id: row.id) { hasPassword = store.hasGuestPassword(row.id) }
    }

    private func act(_ action: LibraryStore.Action) {
        Task { await store.perform(action, on: row.id) }
    }

    /// Onto this Mac's clipboard only (not Universal Clipboard), marked concealed (clipboard managers leave it alone) and
    /// as VMPane's (its clipboard sharing with macOS and Windows guests leaves it alone), and off it again after a minute
    /// unless something else was copied since.
    private func copyPassword() {
        guard let password = store.guestPassword(row.id) else { return }
        let pasteboard = NSPasteboard.general
        let marks = [
            NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"), NSPasteboard.PasteboardType("app.vmpane.guest-password"),
        ]
        pasteboard.prepareForNewContents(with: .currentHostOnly)
        pasteboard.declareTypes([.string] + marks, owner: nil)
        pasteboard.setString(password, forType: .string)
        for mark in marks { pasteboard.setString("", forType: mark) }
        let copied = pasteboard.changeCount
        Task {
            try? await Task.sleep(for: .seconds(60))
            if NSPasteboard.general.changeCount == copied { NSPasteboard.general.clearContents() }
        }
    }
}

/// Processors, memory, disk and display: changed here while the VM is stopped (no helper needed); a running VM says
/// to shut it down first.
private struct ResourcesSection: View {
    let store: LibraryStore
    let row: LibraryStore.Row
    @State private var saved: StoppedSettings?
    @State private var draft: StoppedSettings?
    @State private var problem: String?
    /// What the guest's disk takes so far (its image's allocated blocks), not the bundle with its snapshots.
    @State private var diskUsed: UInt64?

    private static let resolutions = [(1280, 800), (1440, 900), (1920, 1200), (2560, 1600), (1920, 1080), (2560, 1440)]
    private var hostGiB: Int { Int(ProcessInfo.processInfo.physicalMemory >> 30) }
    private var cores: Int { ProcessInfo.processInfo.activeProcessorCount }

    var body: some View {
        Form {
            if let draft = Binding($draft), let saved {
                if row.isRunning {
                    Label("Shut down the VM to change these.", systemImage: "info.circle").foregroundStyle(.secondary)
                }
                if let used = diskUsed {
                    let size = UInt64(saved.diskGiB) << 30
                    let text = "\(ByteCountFormatter.string(fromByteCount: Int64(used), countStyle: .file)) of \(saved.diskGiB) GB used"
                    VStack(alignment: .leading, spacing: 4) {
                        ProgressView(value: Double(min(used, size)), total: Double(max(size, 1)))
                        Text(text).font(.caption).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Disk usage")
                    .accessibilityValue(text)
                }
                Group {
                    Stepper(value: draft.cpuCount, in: 1...cores) {
                        LabeledContent("Processors", value: "\(draft.wrappedValue.cpuCount) of \(cores)")
                    }
                    Stepper(value: gib(draft.memoryMiB), in: 2...max(2, hostGiB - 2)) {
                        LabeledContent("Memory", value: "\(draft.wrappedValue.memoryMiB >> 10) GB")
                    }
                    Text(memoryNote(draft.wrappedValue.memoryMiB >> 10)).font(.caption)
                        .foregroundStyle(hostGiB - draft.wrappedValue.memoryMiB >> 10 < 4 ? .orange : .secondary)
                    Stepper(value: draft.diskGiB, in: saved.diskGiB...max(saved.diskGiB, 2048), step: 8) {
                        LabeledContent("Disk", value: "\(draft.wrappedValue.diskGiB) GB")
                    }
                    Text("A disk can grow, not shrink. The system in the VM grows into the space itself (Linux cloud images do).")
                        .font(.caption).foregroundStyle(.secondary)
                    Picker("Display", selection: resolution(draft)) {
                        ForEach(Self.resolutions, id: \.0) { size in Text(verbatim: "\(size.0) × \(size.1)").tag(size.0) }
                    }
                }
                .disabled(row.isRunning)
                if !row.isRunning {
                    HStack {
                        Button("Revert") { self.draft = saved }.vmCapsule(large: false).disabled(draft.wrappedValue == saved)
                        Spacer()
                        Button("Apply") { Task { await apply(draft.wrappedValue) } }
                            .keyboardShortcut("s", modifiers: .command)
                            .vmCapsule(prominent: true, large: false)
                            .disabled(draft.wrappedValue == saved)
                    }
                }
                if let problem { Text(problem).foregroundStyle(.red).font(.caption) }
            } else {
                ProgressView()
            }
        }
        .formStyle(.grouped)
        .task(id: row.id) { await load() }
        .task(id: row.thumbnailDate) {
            let current = row.bundleURL.appendingPathComponent("current")
            diskUsed = await Task.detached { Self.allocated(in: current) }.value
        }
    }

    /// The allocated size of the disk images (`.img`, `.qcow2`) in `folder`.
    nonisolated private static func allocated(in folder: URL) -> UInt64? {
        let key = URLResourceKey.totalFileAllocatedSizeKey
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [key])) ?? []
        let sizes = files.filter { ["img", "qcow2"].contains($0.pathExtension) }
            .compactMap { try? $0.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize }
        return sizes.isEmpty ? nil : UInt64(sizes.reduce(0, +))
    }

    private func memoryNote(_ gib: Int) -> String {
        let left = hostGiB - gib
        return left < 4 ? "Leaves only \(left) GB for your Mac: it may slow down." : "Leaves \(left) GB for your Mac."
    }

    private func gib(_ mib: Binding<Int>) -> Binding<Int> {
        Binding(get: { mib.wrappedValue >> 10 }, set: { mib.wrappedValue = $0 << 10 })
    }

    private func resolution(_ draft: Binding<StoppedSettings>) -> Binding<Int> {
        Binding(
            get: { draft.wrappedValue.displayWidth },
            set: { width in
                guard let size = Self.resolutions.first(where: { $0.0 == width }) else { return }
                draft.wrappedValue.displayWidth = size.0
                draft.wrappedValue.displayHeight = size.1
            })
    }

    private func load() async {
        do {
            let settings = try await store.resources(row.id)
            saved = settings
            draft = settings
        } catch {
            problem = "\(error)"
        }
    }

    private func apply(_ settings: StoppedSettings) async {
        do {
            try await store.updateResources(row.id, settings)
            saved = settings
            problem = nil
        } catch {
            problem = "Not saved: \(error)"
        }
    }
}

/// The snapshots, current state on top.
private struct SnapshotsSection: View {
    let store: LibraryStore
    let row: LibraryStore.Row
    @State private var model: SnapshotsModel?
    @State private var selection: UUID?
    @State private var restoring: SnapshotMeta?
    @State private var deleting: SnapshotMeta?

    var body: some View {
        VStack(spacing: 0) {
            if let model {
                SnapshotTimeline(model: model, selection: $selection, restoring: $restoring, deleting: $deleting)
                Divider()
                HStack {
                    Button(row.isRunning ? "Take Live Snapshot" : "Take Snapshot") {
                        Task { await model.take(name: HelperViewModel.snapshotName(), running: row.isRunning) }
                    }
                    .disabled(model.busy || row.error != nil)
                    if model.busy { ProgressView().controlSize(.small) }
                    Spacer()
                }
                .padding(12)
            } else {
                ContentUnavailableView("No Snapshots", systemImage: "camera.aperture")
            }
        }
        .task(id: "\(row.id)-\(row.state.map(\.rawValue) ?? "")") {
            model = store.snapshotsModel(row.id)
            await model?.reload()
        }
        .alert("Snapshot failed", isPresented: Binding(get: { model?.lastError != nil }, set: { if !$0 { model?.lastError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model?.lastError ?? "")
        }
    }
}
