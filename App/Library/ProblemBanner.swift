import SwiftUI
import VMPaneCore
import VMPaneUI

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
