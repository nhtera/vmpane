import SwiftUI
import VMPaneCore
import VMPaneUI

/// Which VMs the library shows.
enum LibraryFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case running = "Running"
    case agents = "Agent active"

    var id: String { rawValue }

    var icon: (systemImage: String, color: Color) {
        switch self {
        case .all: ("square.stack.3d.up.fill", .gray)
        case .running: ("play.fill", .green)
        case .agents: ("sparkles", .blue)
        }
    }

    func includes(_ row: LibraryStore.Row) -> Bool {
        switch self {
        case .all: true
        case .running: row.isRunning
        case .agents: row.agentActive
        }
    }
}

/// The library's sidebar: the filters as a source list, each with its icon and how many VMs it holds, and a line
/// on what the library holds. With no VM yet, what it will hold.
struct LibrarySidebar: View {
    let store: LibraryStore
    @Binding var filter: LibraryFilter

    private var isEmpty: Bool { store.rows.isEmpty && store.creations.isEmpty }

    var body: some View {
        Group {
            if isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Virtual Machines").font(.headline)
                    Text("Your VMs appear here, with what each one is doing.").font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(12)
                .contentShape(Rectangle())  // the whole sidebar takes a dropped installer
            } else {
                List(selection: Binding(get: { filter }, set: { if let new = $0 { filter = new } })) {
                    Section("Virtual Machines") {
                        ForEach(LibraryFilter.allCases) { item in
                            Label {
                                Text(item.rawValue)
                            } icon: {
                                SectionIcon(item.icon.systemImage, color: item.icon.color, size: 20)
                            }
                            .badge(store.rows.filter(item.includes).count)
                            .tag(item)
                        }
                    }
                }
                .listStyle(.sidebar)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if !isEmpty {
                Text(summary).font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
        }
    }

    /// "4 VMs · 1 being made".
    private var summary: String {
        let count = store.rows.count
        let made = store.creations.count
        return ["\(count) \(count == 1 ? "VM" : "VMs")", made > 0 ? "\(made) being made" : nil].compactMap { $0 }.joined(separator: " · ")
    }
}
