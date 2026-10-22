import SwiftUI
import VMPaneCore
import VMPaneUI

/// Which VMs the sidebar lists.
enum LibraryFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case running = "Running"
    case agents = "Agent active"

    var id: String { rawValue }

    func includes(_ row: LibraryStore.Row) -> Bool {
        switch self {
        case .all: true
        case .running: row.isRunning
        case .agents: row.agentActive
        }
    }
}

/// The library's sidebar: every VM as a row (thumbnail, name, system, state, agent) or as a card in a grid.
struct LibrarySidebar: View {
    @Bindable var store: LibraryStore
    @Binding var filter: LibraryFilter
    let grid: Bool
    let onAction: (LibraryStore.Row, SidebarAction) -> Void

    enum SidebarAction {
        case clone, delete, primary
    }

    private var rows: [LibraryStore.Row] { store.rows.filter(filter.includes) }

    var body: some View {
        Group {
            if grid {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 12)], spacing: 12) {
                        ForEach(rows) { row in
                            VMCard(row: row, selected: store.selection == row.id)
                                .onTapGesture { store.selection = row.id }
                                .onTapGesture(count: 2) { onAction(row, .primary) }
                                .contextMenu { menu(row) }
                        }
                    }
                    .padding(12)
                }
            } else {
                List(rows, selection: $store.selection) { row in
                    VMRowView(row: row)
                        .tag(row.id)
                        .contextMenu { menu(row) }
                }
            }
        }
        .safeAreaInset(edge: .top) {
            Picker("Show", selection: $filter) {
                ForEach(LibraryFilter.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .overlay {
            if rows.isEmpty, !store.rows.isEmpty {
                Text(filter == .running ? "No VM is running." : "No agent is using a VM.").foregroundStyle(.secondary)
            }
        }
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

/// One VM in the list: its last picture, its name, system and state, and an agent at work.
struct VMRowView: View {
    let row: LibraryStore.Row

    var body: some View {
        HStack(spacing: 8) {
            VMThumbnail(row: row).frame(width: 64, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name).lineLimit(1)
                HStack(spacing: 6) {
                    Text(OSBadge.name(row.os)).font(.caption).foregroundStyle(.secondary)
                    StateDot(row.state, suspended: row.suspended)
                }
                if row.agentActive, let client = row.agentClient { AgentBadge(client: client) }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.spoken(row))
    }

    /// The row as one sentence ("Debian 13, Linux, running, Claude acting").
    static func spoken(_ row: LibraryStore.Row) -> String {
        var parts = [row.name, OSBadge.name(row.os), StateDot.label(row.state, suspended: row.suspended).lowercased()]
        if row.agentActive, let client = row.agentClient { parts.append("\(client) acting") }
        if row.error != nil { parts.append("has a problem") }
        return parts.joined(separator: ", ")
    }
}

/// One VM in the grid.
struct VMCard: View {
    let row: LibraryStore.Row
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            VMThumbnail(row: row).aspectRatio(16 / 10, contentMode: .fit)
            Text(row.name).font(.callout).lineLimit(1)
            StateDot(row.state, suspended: row.suspended)
            if row.agentActive, let client = row.agentClient { AgentBadge(client: client) }
        }
        .padding(6)
        .background(selected ? Color.accentColor.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(VMRowView.spoken(row))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// The helper's last picture of the guest (reloaded when it changes), else the system's symbol.
struct VMThumbnail: View {
    let row: LibraryStore.Row
    var cornerRadius: CGFloat = 6
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).fill(.quaternary)
            if let image {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                Image(systemName: OSBadge.symbol(row.os)).imageScale(.large).foregroundStyle(.secondary)
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
