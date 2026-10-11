import SwiftUI
import VMPaneCore

/// The VM's snapshots: take one, restore (after saying what is lost), delete.
public struct SnapshotsSheet: View {
    @Bindable var model: SnapshotsModel
    let running: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var newName = ""
    @State private var restoring: SnapshotMeta?
    @State private var deleting: SnapshotMeta?

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
            List(model.snapshots, id: \.id) { snapshot in
                SnapshotRow(snapshot: snapshot)
                    .contextMenu {
                        if snapshot.origin == .agentSession {
                            // Taken before an AI agent's first change: going back undoes that session.
                            Button("Undo This Agent Session…") { restoring = snapshot }
                        }
                        Button("Restore…") { restoring = snapshot }
                        Button("Delete…", role: .destructive) { deleting = snapshot }
                    }
            }
            .overlay {
                if model.snapshots.isEmpty {
                    ContentUnavailableView(
                        "No Snapshots", systemImage: "camera.aperture",
                        description: Text("A snapshot keeps this VM as it is now, to come back to later."))
                }
            }
            Divider()
            HStack {
                if model.busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 520, height: 480)
        .task { await model.reload() }
        .confirmationDialog(title("Restore", restoring), isPresented: shown($restoring), presenting: restoring) { snapshot in
            Button("Restore") { Task { await model.restore(snapshot.id) } }
        } message: { snapshot in
            Text(SnapshotsModel.restoreWarning(snapshot))
        }
        .confirmationDialog(title("Delete", deleting), isPresented: shown($deleting), presenting: deleting) { snapshot in
            Button("Delete", role: .destructive) { Task { await model.delete(snapshot.id) } }
        } message: { _ in
            Text("The snapshot's disks and saved memory are removed. This cannot be undone.")
        }
        .alert("Snapshot failed", isPresented: Binding(get: { model.lastError != nil }, set: { if !$0 { model.lastError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.lastError ?? "")
        }
    }

    private func title(_ verb: String, _ snapshot: SnapshotMeta?) -> String { "\(verb) “\(snapshot?.name ?? "")”?" }

    private func shown(_ item: Binding<SnapshotMeta?>) -> Binding<Bool> {
        Binding(get: { item.wrappedValue != nil }, set: { if !$0 { item.wrappedValue = nil } })
    }
}

private struct SnapshotRow: View {
    let snapshot: SnapshotMeta

    var body: some View {
        HStack {
            Image(systemName: snapshot.kind == .live ? "memorychip" : "internaldrive").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(snapshot.name)
                Text(snapshot.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if snapshot.kind == .live {
                Text("Contains RAM")
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.orange.opacity(0.15), in: Capsule())
                    .help("Live snapshots include the VM's memory: anything in it, passwords and keys too, is in the snapshot.")
            }
            if snapshot.origin == .agentSession {
                Text("Before agent").font(.caption2).foregroundStyle(.secondary)
            }
            ByteSizeText(snapshot.sizeBytes).font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
