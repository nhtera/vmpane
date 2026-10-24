import SwiftUI
import VMPaneCore
import VMPaneUI

/// The library's VMs under the sidebar's filter, as a list or a grid: each VM's last picture, name, state and system,
/// an agent at work, its size; VMs being made with their progress.
struct LibraryContent: View {
    @Bindable var store: LibraryStore
    let filter: LibraryFilter
    let grid: Bool
    let onAction: (LibraryStore.Row, Action) -> Void

    enum Action {
        case clone, delete, primary
    }

    private var rows: [LibraryStore.Row] { store.rows.filter(filter.includes) }

    var body: some View {
        Group {
            if grid {
                ScrollView {
                    ForEach(store.creations) { CreationRow(store: store, creation: $0).padding(.horizontal, 16) }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 16)], spacing: 16) {
                        ForEach(rows) { row in
                            VMCard(row: row, selected: store.selection == row.id)
                                .onTapGesture(count: 2) { onAction(row, .primary) }
                                .onTapGesture { store.selection = row.id }
                                .contextMenu { menu(row) }
                        }
                    }
                    .padding(16)
                }
            } else {
                List(selection: $store.selection) {
                    ForEach(store.creations) { CreationRow(store: store, creation: $0) }
                    ForEach(rows) { VMRowView(row: $0).tag($0.id) }
                }
                // A double-click or Return starts the VM or shows its window, with or without the inspector.
                .contextMenu(forSelectionType: UUID.self) { ids in
                    if let id = ids.first, let row = store.row(id) { menu(row) }
                } primaryAction: { ids in
                    if let id = ids.first, let row = store.row(id) { onAction(row, .primary) }
                }
            }
        }
        .overlay {
            if rows.isEmpty, store.creations.isEmpty {
                ContentUnavailableView(
                    filter == .running ? "No VM Is Running" : "No Agent Is Using a VM",
                    systemImage: filter == .running ? "play.circle" : "sparkles")
            }
        }
        .navigationTitle(filter.rawValue)
        .navigationSubtitle(store.selection.flatMap(store.row)?.name ?? "")
    }

    @ViewBuilder private func menu(_ row: LibraryStore.Row) -> some View {
        VMActionMenu(store: store, row: row)
        if !row.isRunning {
            Divider()
            Button("Clone…") { onAction(row, .clone) }
            Button("Delete…", role: .destructive) { onAction(row, .delete) }
        }
    }
}

/// One VM in the list: its last picture with its system's tile, its name, state and system, its size, and an agent at
/// work.
struct VMRowView: View {
    let row: LibraryStore.Row

    var body: some View {
        HStack(spacing: 12) {
            VMThumbnail(row: row)
                .frame(width: 96, height: 60)
                .overlay(alignment: .bottomTrailing) { SystemTile(row.system, size: 22).padding(4) }
            VStack(alignment: .leading, spacing: 3) {
                Text(row.name).font(.headline).lineLimit(1)
                HStack(spacing: 6) {
                    StateDot(row.state, suspended: row.suspended).fixedSize()
                    Text("· \(row.systemName)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if let spec = row.spec { Text(spec).font(.caption).foregroundStyle(.secondary).monospacedDigit() }
                if let install = row.install, install.isActive {
                    ProgressView(value: Double(install.percent), total: 100).controlSize(.small)
                    Text(install.message).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if row.error != nil { ProblemMark() }
                if row.restartToUpdate { UpdateMark() }
                if row.agentActive, let client = row.agentClient { AgentBadge(client: row.agentLine(client)) }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.spoken(row))
    }

    /// The row as one sentence ("Debian 13, Linux, running, Claude Code acting").
    static func spoken(_ row: LibraryStore.Row) -> String {
        var parts = [row.name, row.systemName, StateDot.label(row.state, suspended: row.suspended).lowercased()]
        if let install = row.install, install.isActive { parts.append("installing, \(install.percent) percent") }
        if row.agentActive, let client = row.agentClient { parts.append("\(client) acting") }
        if row.error != nil { parts.append("has a problem") }
        if row.restartToUpdate { parts.append("restart it to update") }
        return parts.joined(separator: ", ")
    }
}

/// One VM in the grid: its last picture (16:10), name and state.
struct VMCard: View {
    let row: LibraryStore.Row
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            VMThumbnail(row: row, cornerRadius: 10)
                .aspectRatio(16 / 10, contentMode: .fit)
                .overlay(alignment: .bottomTrailing) { SystemTile(row.system, size: 22).padding(6) }
            Text(row.name).font(.headline).lineLimit(1)
            StateDot(row.state, suspended: row.suspended)
            if row.error != nil { ProblemMark() }
            if row.agentActive, let client = row.agentClient { AgentBadge(client: row.agentLine(client)) }
        }
        .padding(8)
        .background(selected ? Color.accentColor.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(VMRowView.spoken(row))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// The helper's last picture of the guest (reloaded when it changes), else an empty screen.
struct VMThumbnail: View {
    let row: LibraryStore.Row
    var cornerRadius: CGFloat = 8
    @State private var image: NSImage?

    var body: some View {
        // The picture fills the frame it is given and is cut to it (a 16:9 or 4:3 screen in a 16:10 frame).
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).fill(.quaternary)
            .overlay {
                if let image {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: "display").imageScale(.large).foregroundStyle(.tertiary)  // the tile is on the badge
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .opacity(row.isRunning || image == nil ? 1 : 0.7)
            .accessibilityHidden(true)
            .task(id: row.thumbnailDate) {
                guard let url = row.thumbnail else { return image = nil }
                image = await Task.detached { NSImage(contentsOf: url) }.value
            }
    }
}

/// A VM still running on the VMPane it started with, before an update: a restart moves it to this one.
struct UpdateMark: View {
    var body: some View {
        Label("Restart to update", systemImage: "arrow.triangle.2.circlepath").font(.caption).foregroundStyle(.secondary)
            .help("This VM still runs on the VMPane it started with. Shut it down and start it again to use this version.")
    }
}

/// A VM that cannot start as it is: said in words, not only by colour (the inspector has the fix).
private struct ProblemMark: View {
    var body: some View {
        Label("Has a problem", systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
    }
}

extension LibraryStore.Row {
    /// "Claude Code · Full control".
    fileprivate func agentLine(_ client: String) -> String {
        [client, policy?.title].compactMap { $0 }.joined(separator: " · ")
    }
}
