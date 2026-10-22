import SwiftUI
import VMPaneUI

/// The menu bar extra: running VMs with their quick actions, and the way back to the library.
struct MenuBarExtraView: View {
    let store: LibraryStore
    let killSwitch: AgentKillSwitch
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let running = store.rows.filter(\.isRunning)
        if running.isEmpty {
            Text("No VMs running")
        } else {
            ForEach(running) { row in
                Menu("\(row.name) — \(StateDot.label(row.state))") {
                    Button("Show Window") { act(.showWindow, row) }
                    if row.state == .paused {
                        Button("Resume") { act(.resume, row) }
                    } else {
                        Button("Pause") { act(.pause, row) }
                    }
                    Button("Shut Down") { act(.stop(force: false), row) }
                }
            }
        }
        Divider()
        AgentKillSwitchMenu(killSwitch: killSwitch)
        Divider()
        Button("Open VMPane") {
            openWindow(id: "library")
            NSApp.activate()
        }
        Button("Quit VMPane") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func act(_ action: LibraryStore.Action, _ row: LibraryStore.Row) {
        Task { await store.perform(action, on: row.id) }
    }
}

/// VMPane's menu bar icon: filled while an AI agent acts on any VM. A view of its own, so it follows the library (the
/// App's body does not).
struct MenuBarIcon: View {
    let store: LibraryStore

    var body: some View {
        let acting = store.rows.contains(where: \.agentActive)
        Image(systemName: acting ? "square.stack.3d.up.fill" : "square.stack.3d.up")
            .accessibilityLabel(acting ? "VMPane, an AI agent is acting" : "VMPane")
    }
}
