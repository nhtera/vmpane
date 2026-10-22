import SwiftUI
import VMPaneCore

/// A VM's snapshots, newest first under the state it is in now: restore (after saying what is lost), rename, delete.
/// The library's inspector and the VM window's sheet show it.
public struct SnapshotTimeline: View {
    @Bindable var model: SnapshotsModel
    @Binding var selection: UUID?
    @Binding var restoring: SnapshotMeta?
    @Binding var deleting: SnapshotMeta?
    @State private var renaming: SnapshotMeta?
    @State private var newName = ""

    public init(
        model: SnapshotsModel, selection: Binding<UUID?>, restoring: Binding<SnapshotMeta?>, deleting: Binding<SnapshotMeta?>
    ) {
        self.model = model
        _selection = selection
        _restoring = restoring
        _deleting = deleting
    }

    public var body: some View {
        List(selection: $selection) {
            Label("Now", systemImage: "circle.fill")
                .font(.callout).foregroundStyle(.secondary)
                .accessibilityLabel("The VM as it is now")
                .selectionDisabled()
            ForEach(model.snapshots, id: \.id) { snapshot in
                SnapshotRow(snapshot: snapshot)
                    .tag(snapshot.id)
                    .contextMenu {
                        if snapshot.origin == .agentSession {
                            // Taken before an AI agent's first change: going back undoes that session.
                            Button("Undo This Agent Session…") { restoring = snapshot }
                        }
                        Button("Restore…") { restoring = snapshot }
                        Button("Rename…") {
                            newName = snapshot.name
                            renaming = snapshot
                        }
                        Button("Delete…", role: .destructive) { deleting = snapshot }
                    }
            }
        }
        .overlay {
            if model.snapshots.isEmpty {
                ContentUnavailableView(
                    "No Snapshots", systemImage: "camera.aperture",
                    description: Text("A snapshot keeps this VM as it is now, to come back to later."))
            }
        }
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
        .alert("Rename Snapshot", isPresented: shown($renaming), presenting: renaming) { snapshot in
            TextField("Name", text: $newName)
            Button("Rename") {
                let name = newName.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { Task { await model.rename(snapshot.id, to: name) } }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func title(_ verb: String, _ snapshot: SnapshotMeta?) -> String { "\(verb) “\(snapshot?.name ?? "")”?" }

    private func shown(_ item: Binding<SnapshotMeta?>) -> Binding<Bool> {
        Binding(get: { item.wrappedValue != nil }, set: { if !$0 { item.wrappedValue = nil } })
    }
}

struct SnapshotRow: View {
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
                .help("Space this snapshot takes of its own: what deleting it frees. It grows as the VM changes.")
        }
        .accessibilityElement(children: .combine)
    }
}
