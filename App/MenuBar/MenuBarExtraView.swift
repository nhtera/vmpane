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
