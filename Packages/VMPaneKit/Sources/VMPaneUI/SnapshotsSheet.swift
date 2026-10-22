import SwiftUI
import VMPaneCore

/// The VM's snapshots in a sheet (the VM window): take one, and the timeline (`SnapshotTimeline`).
public struct SnapshotsSheet: View {
    /// Its height when the window has room; smaller windows get a shorter sheet (the list scrolls).
    static let idealHeight: CGFloat = 480
    @Bindable var model: SnapshotsModel
    let running: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var newName = ""
    @State private var restoring: SnapshotMeta?
    @State private var deleting: SnapshotMeta?
    @State private var selection: UUID?

    public init(model: SnapshotsModel, running: Bool) {
        self.model = model
        self.running = running
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Snapshot name", text: $newName)
                Button(running ? "Take Live Snapshot" : "Take Snapshot") {
                    let name = newName.trimmingCharacters(in: .whitespaces)
                    Task {
                        await model.take(name: name.isEmpty ? HelperViewModel.snapshotName() : name, running: running)
                        newName = ""
                    }
                }
                .disabled(model.busy)
            }
            .padding()
            Divider()
            SnapshotTimeline(model: model, selection: $selection, restoring: $restoring, deleting: $deleting)
            Divider()
            HStack {
                let selected = model.snapshots.first { $0.id == selection }
                Button(selected?.origin == .agentSession ? "Undo Agent Session…" : "Restore…") { restoring = selected }
                    .disabled(selected == nil || model.busy)
                Button("Delete…", role: .destructive) { deleting = selected }
                    .disabled(selected == nil || model.busy)
                if model.busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 520)
        .frame(minHeight: 300, idealHeight: Self.idealHeight)
        .task { await model.reload() }
        .alert("Snapshot failed", isPresented: Binding(get: { model.lastError != nil }, set: { if !$0 { model.lastError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.lastError ?? "")
        }
    }
}
