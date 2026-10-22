import SwiftUI
import VMPaneCore
import VMPaneUI

/// The selected VM in detail: its system, its hardware (changed on a stopped VM with no helper), its snapshots and
/// what AI agents did with it.
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
            Picker("Section", selection: $section) {
                ForEach(Section.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(12)
            Divider()
            switch section {
            case .system: SystemSection(store: store, row: row)
            case .resources: ResourcesSection(store: store, row: row)
            case .snapshots: SnapshotsSection(store: store, row: row)
            case .activity: Form { AgentActivityView(bundle: row.bundleURL) }.formStyle(.grouped)
            }
        }
        .inspectorColumnWidth(min: 280, ideal: 320, max: 420)
    }
}

/// What the VM is: system, guest tools, where it is.
private struct SystemSection: View {
    let store: LibraryStore
    let row: LibraryStore.Row
    @State private var guest: (osVersion: String?, toolsVersion: String?) = (nil, nil)
    @State private var hasPassword = false

    var body: some View {
        Form {
            LabeledContent("System", value: OSBadge.name(row.os))
            LabeledContent("Version", value: guest.osVersion ?? (row.isRunning ? "—" : "Start it to read"))
            LabeledContent("Guest tools", value: guest.toolsVersion ?? (row.isRunning ? "Not running" : "—"))
            LabeledContent("State") { StateDot(row.state, suspended: row.suspended) }
            LabeledContent("On disk") { ByteSizeText(row.diskBytes) }
            LabeledContent("Location") {
                Text(row.bundleURL.path).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
            }
            if hasPassword {
                LabeledContent("Account password") {
                    Button("Copy Password") { copyPassword() }
                        .help("The guest account's password VMPane keeps for you; the clipboard forgets it after a minute")
                }
            }
        }
        .formStyle(.grouped)
        .task(id: row.state) { guest = await store.guestInfo(row.id) }
        .task(id: row.id) { hasPassword = store.hasGuestPassword(row.id) }
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

    private static let resolutions = [(1280, 800), (1440, 900), (1920, 1200), (2560, 1600), (1920, 1080), (2560, 1440)]
    private var hostGiB: Int { Int(ProcessInfo.processInfo.physicalMemory >> 30) }
    private var cores: Int { ProcessInfo.processInfo.activeProcessorCount }

    var body: some View {
        Form {
            if let draft = Binding($draft), let saved {
                if row.isRunning {
                    Label("Shut down the VM to change these.", systemImage: "info.circle").foregroundStyle(.secondary)
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
                        Button("Revert") { self.draft = saved }.disabled(draft.wrappedValue == saved)
                        Spacer()
                        Button("Apply") { Task { await apply(draft.wrappedValue) } }
                            .keyboardShortcut("s", modifiers: .command)
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
