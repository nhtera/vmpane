import SwiftUI
import VMPaneCore
import VMPaneHost
import VMPaneUI

/// The VM library: the filters in the sidebar, their VMs as a list or a grid, and the selected one in the inspector.
struct LibraryWindow: View {
    @Bindable var store: LibraryStore
    @State private var newVM: NewVMStart?
    @State private var cloning: LibraryStore.Row?
    @State private var cloneName = ""
    @State private var deleting: LibraryStore.Row?
    @State private var importing: URL?
    @State private var filter = LibraryFilter.all
    @State private var showInspector = true
    @State private var inspectorSection = VMInspector.Section.system
    @AppStorage("onboarded") private var onboarded = false
    @AppStorage("libraryGrid") private var grid = false

    var body: some View {
        NavigationSplitView {
            LibrarySidebar(store: store, filter: $filter)
                .navigationSplitViewColumnWidth(min: 200, ideal: 220)
                .dropDestination(for: URL.self) { urls, _ in drop(urls) }
        } detail: {
            if store.rows.isEmpty, store.creations.isEmpty {
                // In the detail area: on the sidebar's translucent background the title fails contrast, and it wraps.
                EmptyLibrary { newVM = NewVMStart(card: $0) }
                    .dropDestination(for: URL.self) { urls, _ in drop(urls) }
            } else {
                LibraryContent(store: store, filter: filter, grid: grid) { row, action in
                    switch action {
                    case .clone:
                        cloneName = "\(row.name) copy"
                        cloning = row
                    case .delete: deleting = row
                    case .primary: Task { await store.perform(row.isRunning ? .showWindow : .start(headless: false), on: row.id) }
                    }
                }
                .dropDestination(for: URL.self) { urls, _ in drop(urls) }
                .onDeleteCommand {
                    if let id = store.selection, let row = store.row(id), !row.isRunning { deleting = row }
                }
                .inspector(isPresented: $showInspector) {
                    if let id = store.selection, let row = store.row(id) {
                        VMInspector(store: store, row: row, section: $inspectorSection).id(row.id)  // nothing of the last VM
                    } else {
                        ContentUnavailableView("No VM Selected", systemImage: "sidebar.right")
                            .inspectorColumnWidth(min: 280, ideal: 300, max: 420)
                    }
                }
            }
        }
        .navigationTitle("VMPane")
        .toolbar {
            ToolbarItem(placement: .secondaryAction) {
                Button("Import from Parallels…", systemImage: "square.and.arrow.down") { chooseParallelsVM() }
                    .help("Make a VMPane VM from a Parallels virtual machine")
            }
            ToolbarItem(placement: .primaryAction) {
                Button("New VM", systemImage: "plus") { newVM = NewVMStart() }
                    .help("Create a virtual machine")
                    .keyboardShortcut("n", modifiers: .command)
            }
            ToolbarItem(placement: .secondaryAction) {
                Picker("View", selection: $grid) {
                    Label("List", systemImage: "list.bullet").tag(false)
                    Label("Grid", systemImage: "square.grid.2x2").tag(true)
                }
                .pickerStyle(.segmented)
                .accessibilityLabel("View")
                .help("Show the VMs as a list or a grid")
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Inspector", systemImage: "sidebar.right") { showInspector.toggle() }
                    .help("Show or hide the inspector")
                    .keyboardShortcut("i", modifiers: .command)
                    .disabled(store.rows.isEmpty && store.creations.isEmpty)
            }
        }
        // A VM the filter hides is no longer chosen (Delete or Return would act on it); one with a problem shows the
        // inspector, which has the fix.
        .onChange(of: filter) { _, filter in
            if let row = store.selection.flatMap(store.row), !filter.includes(row) { store.selection = nil }
        }
        .onChange(of: store.selection) { _, id in
            if let row = id.flatMap(store.row), row.error != nil { showInspector = true }
        }
        .sheet(item: $newVM) { NewVMWizard(store: store, start: $0) }
        .onChange(of: store.installerToUse, initial: true) { _, installer in
            guard let installer else { return }
            store.installerToUse = nil
            useInstaller(installer)
        }
        .sheet(item: $importing) { pvm in ImportParallelsSheet(store: store, pvm: pvm) }
        .onChange(of: store.parallelsToImport, initial: true) { _, pvm in
            guard let pvm else { return }
            importing = pvm
            store.parallelsToImport = nil
        }
        .alert("Clone “\(cloning?.name ?? "")”", isPresented: present($cloning)) {
            TextField("Name", text: $cloneName)
            Button("Clone") {
                if let row = cloning { Task { await store.clone(row.id, name: cloneName) } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The copy is a new machine with its own identity.")
        }
        .confirmationDialog("Delete “\(deleting?.name ?? "")”?", isPresented: present($deleting)) {
            Button("Delete", role: .destructive) {
                if let row = deleting { Task { await store.delete(row.id) } }
            }
        } message: {
            if deleting?.isMissing == true {
                Text("It is no longer on disk; this takes it off the list.")
            } else {
                Text("Its disks and snapshots are deleted too. This cannot be undone.")
            }
        }
        .sheet(isPresented: Binding(get: { !onboarded }, set: { if !$0 { onboarded = true } })) {
            OnboardingFlow { onboarded = true }
        }
        .task {
            await store.reload()
            // The library changes from outside too (the CLI, Finder): look again now and then.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                await store.reload()
            }
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(get: { store.lastError != nil }, set: { if !$0 { store.lastError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.lastError ?? "")
        }
    }
}

extension LibraryWindow {
    /// Files dropped on the library: VMs join it; an installer (.iso, .ipsw) opens the new-VM sheet with it.
    fileprivate func drop(_ urls: [URL]) -> Bool {
        let bundles = urls.filter { $0.pathExtension == VMPane.bundleExtension }
        if !bundles.isEmpty { Task { await store.importBundles(bundles) } }
        if let installer = urls.first(where: { ["iso", "ipsw"].contains($0.pathExtension.lowercased()) }) { useInstaller(installer) }
        return !bundles.isEmpty || urls.contains { ["iso", "ipsw"].contains($0.pathExtension.lowercased()) }
    }

    /// Reads what the installer is (an ISO is mounted for a moment, off the main thread), then opens the sheet with
    /// it, or says why VMPane cannot use it; nothing is copied before that.
    fileprivate func useInstaller(_ url: URL) {
        Task {
            do {
                let kind = try await Blocking.run { try InstallMediaKind.detect(url) }
                newVM = NewVMStart(media: (url, kind))
            } catch {
                store.lastError = String(describing: error)
            }
        }
    }

    /// Asks for a Parallels `.pvm` (the default Parallels folder first).
    fileprivate func chooseParallelsVM() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.parallelsVM]
        panel.treatsFilePackagesAsDirectories = false
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Parallels")
        panel.message = "Choose a Parallels virtual machine (.pvm)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importing = url
    }
}

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}

private func present<T>(_ item: Binding<T?>) -> Binding<Bool> {
    Binding(get: { item.wrappedValue != nil }, set: { if !$0 { item.wrappedValue = nil } })
}

/// Start/stop and friends, for the context menu and the inspector's More menu.
struct VMActionMenu: View {
    let store: LibraryStore
    let row: LibraryStore.Row

    var body: some View {
        if row.isRunning {
            Button("Show Window") { act(.showWindow) }
            Divider()
            if row.state == .paused {
                Button("Resume") { act(.resume) }
            } else {
                Button("Pause") { act(.pause) }
            }
            Button("Suspend") { act(.suspend) }
            Button("Shut Down") { act(.stop(force: false)) }
            Button("Force Stop") { act(.stop(force: true)) }
        } else {
            // A VM whose config cannot be read (moved, deleted, damaged) cannot start.
            Group {
                Button(row.suspended ? "Resume" : "Start") { act(.start(headless: false)) }
                Button(row.suspended ? "Resume Without Window" : "Start Without Window") { act(.start(headless: true)) }
            }
            .disabled(row.error != nil)
        }
        Divider()
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([row.bundleURL]) }
            .disabled(row.isMissing)
        if row.error != nil, !row.isRunning {
            Button("Remove from Library") { Task { await store.removeFromLibrary(row.id) } }
        }
    }

    private func act(_ action: LibraryStore.Action) {
        Task { await store.perform(action, on: row.id) }
    }
}

/// The library with no VM yet: three systems to start from, the others in the new-VM sheet, and where an installer
/// can be dropped (the whole view takes the drop).
private struct EmptyLibrary: View {
    /// Opens the new-VM sheet on a card (nil: on the last one used, with the full list).
    let choose: (WizardModel.Card?) -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                VStack(spacing: 6) {
                    Text("Create your first VM").font(.largeTitle.bold())
                    Text("macOS, Linux and Windows on this Mac, each in a window of its own.").foregroundStyle(.secondary)
                }
                HStack(spacing: 14) {
                    tile(.macos, "Latest from Apple")
                    tile(.ubuntu, "\(WizardModel.Card.ubuntu.versionText(in: .bundled) ?? "") · ready in minutes")
                    tile(.windows, "for Arm, installed for you")
                }
                Button("More systems: Debian, Fedora, an installer file…") { choose(nil) }.vmCapsule(large: false)
                VStack(spacing: 10) {
                    Label("Or drop an installer (.iso or .ipsw) here", systemImage: "arrow.down.doc")
                        .frame(maxWidth: .infinity)
                        .padding(18)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
                    Label("AI agents cannot see a VM until you allow it.", systemImage: "lock.shield")
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: 560)
            }
            .padding(30)
            .frame(maxWidth: .infinity)
        }
        .defaultScrollAnchor(.center)
    }

    /// A quick-start tile: a real button (Tab reaches it), named by its system.
    private func tile(_ card: WizardModel.Card, _ line: String) -> some View {
        Button {
            choose(card)
        } label: {
            VStack(spacing: 10) {
                SystemTile(SystemTile.System(card), size: 64)
                VStack(spacing: 2) {
                    Text(card.title).font(.headline)
                    Text(line).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
            }
            .frame(width: 160, height: 150)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(card.title)
        .accessibilityHint(line)
    }
}
