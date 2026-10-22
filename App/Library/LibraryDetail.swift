import SwiftUI
import VMPaneCore
import VMPaneUI

/// The selected VM on the stage: its screen as last seen (a click shows the window, or starts it), what it is, the main
/// actions, and a problem with its fix.
struct LibraryDetail: View {
    let store: LibraryStore
    let row: LibraryStore.Row
    /// Opens the inspector at a section (the fix for a problem may be there).
    let showInspector: (VMInspector.Section) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Button {
                    act(row.isRunning ? .showWindow : .start(headless: false))
                } label: {
                    VMThumbnail(row: row, cornerRadius: 16)
                        .aspectRatio(16 / 10, contentMode: .fit)
                        .frame(maxWidth: 720)
                }
                .buttonStyle(.plain)
                .disabled(row.error != nil)
                .accessibilityLabel(row.isRunning ? "Show \(row.name)'s window" : "Start \(row.name)")
                .help(row.isRunning ? "Show this VM's window" : "Start this VM")

                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(row.name).font(.title2).bold()
                        HStack(spacing: 8) {
                            Text(OSBadge.name(row.os)).foregroundStyle(.secondary)
                            StateDot(row.state, suspended: row.suspended)
                            if row.agentActive, let client = row.agentClient { AgentBadge(client: client) }
                        }
                    }
                    Spacer()
                    primaryActions
                }

                if let error = row.error { ProblemBanner(store: store, row: row, message: error, showInspector: showInspector) }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(row.name)
    }

    @ViewBuilder private var primaryActions: some View {
        HStack {
            if row.isRunning {
                Button("Show Window", systemImage: "macwindow") { act(.showWindow) }
                    .keyboardShortcut(.return, modifiers: [])
                Button("Shut Down", systemImage: "power") { act(.stop(force: false)) }
                    .keyboardShortcut(".", modifiers: .command)
            } else {
                Button(row.suspended ? "Resume" : "Start", systemImage: "play.fill") { act(.start(headless: false)) }
                    .keyboardShortcut(.return, modifiers: [])
                    .disabled(row.error != nil)
            }
        }
        .controlSize(.large)
    }

    private func act(_ action: LibraryStore.Action) {
        Task { await store.perform(action, on: row.id) }
    }
}

/// A VM's problem: the known cause and its fix (`ErrorExplainer`), else the message as it is; and a way to report it.
struct ProblemBanner: View {
    let store: LibraryStore
    let row: LibraryStore.Row
    let message: String
    let showInspector: (VMInspector.Section) -> Void

    var body: some View {
        let explained = ErrorExplainer.explain(message)
        VStack(alignment: .leading, spacing: 8) {
            Label(explained?.title ?? "This VM has a problem", systemImage: "exclamationmark.triangle.fill")
                .font(.headline).foregroundStyle(.orange)
            Text(explained?.fix ?? message)
            if explained != nil { Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            HStack {
                if let action = explained?.action, let title = explained?.actionTitle {
                    Button(title) { perform(action) }
                } else if !row.isRunning {
                    Button("Remove from Library") { perform(.removeFromLibrary) }
                        .help("Takes this VM off the list. Nothing on disk is deleted.")
                }
                Button("Copy Diagnostics") { ErrorExplainer.copyDiagnostics(for: message, vm: row.name) }
                    .help("Copies VMPane's and macOS's versions and the error, for a bug report")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    private func perform(_ action: ErrorExplanation.Action) {
        switch action {
        case .editResources: showInspector(.resources)
        case .openStorageSettings:
            if let url = URL(string: "x-apple.systempreferences:com.apple.settings.Storage") { NSWorkspace.shared.open(url) }
        case .showInFinder: NSWorkspace.shared.activateFileViewerSelecting([row.bundleURL])
        case .removeFromLibrary: Task { await store.removeFromLibrary(row.id) }
        }
    }
}
