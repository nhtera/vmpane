import SwiftUI
import VMPaneCore
import VMPaneUI

/// The VM library: running and stopped VMs on the left, the selected one's details and actions on the right.
struct LibraryWindow: View {
    @Bindable var store: LibraryStore
    @State private var showingWizard = false
    @AppStorage("onboarded") private var onboarded = false

    var body: some View {
        NavigationSplitView {
            List(store.rows, selection: $store.selection) { row in
                VMRowView(row: row)
                    .tag(row.id)
                    .contextMenu { VMActionMenu(store: store, row: row) }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 260)
            .overlay {
                if store.rows.isEmpty {
                    ContentUnavailableView {
                        Label("No Virtual Machines", systemImage: "square.stack.3d.up")
                    } description: {
                        Text("Create a VM to get started.")
                    } actions: {
                        Button("New VM…") { showingWizard = true }
                    }
                }
            }
        } detail: {
            if let id = store.selection, let row = store.row(id) {
                VMDetailView(store: store, row: row)
            } else {
                Text("Select a VM").foregroundStyle(.secondary)
            }
        }
        .navigationTitle("VMPane")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("New VM", systemImage: "plus") { showingWizard = true }
                    .help("Create a virtual machine")
                    .keyboardShortcut("n", modifiers: .command)
            }
        }
        .sheet(isPresented: $showingWizard) { NewVMWizard(store: store) }
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

/// One VM in the list.
struct VMRowView: View {
    let row: LibraryStore.Row

    var body: some View {
        HStack(spacing: 8) {
            OSBadge(row.os)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name).lineLimit(1)
                StateDot(row.state)
            }
            Spacer()
            ByteSizeText(row.diskBytes).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// Start/stop and friends, for the context menu and the detail toolbar.
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
            Button("Start") { act(.start(headless: false)) }
            Button("Start Without Window") { act(.start(headless: true)) }
        }
        Divider()
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([row.bundleURL]) }
    }

    private func act(_ action: LibraryStore.Action) {
        Task { await store.perform(action, on: row.id) }
    }
}

/// The selected VM.
struct VMDetailView: View {
    let store: LibraryStore
    let row: LibraryStore.Row

    var body: some View {
        Form {
            Section {
                LabeledContent("Name", value: row.name)
                LabeledContent("System", value: OSBadge.name(row.os))
                LabeledContent("State") { StateDot(row.state) }
                LabeledContent("On disk") { ByteSizeText(row.diskBytes) }
                LabeledContent("Location") {
                    Text(row.bundleURL.path).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                }
            }
            if let error = row.error {
                Section("Problem") { Text(error).foregroundStyle(.red) }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(row.name)
        .toolbar {
            ToolbarItemGroup {
                if row.isRunning {
                    Button("Show Window", systemImage: "macwindow") { act(.showWindow) }
                        .help("Show this VM's window")
                    Button("Shut Down", systemImage: "power") { act(.stop(force: false)) }
                        .help("Shut down the guest")
                } else {
                    Button("Start", systemImage: "play.fill") { act(.start(headless: false)) }
                        .help("Start this VM")
                        .keyboardShortcut("r", modifiers: .command)
                }
            }
        }
    }

    private func act(_ action: LibraryStore.Action) {
        Task { await store.perform(action, on: row.id) }
    }
}
