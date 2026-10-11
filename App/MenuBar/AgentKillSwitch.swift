import Carbon.HIToolbox
import Observation
import SwiftUI
import VMPaneCore

/// The app's side of the agent kill switch (`KillSwitch`): its state for the menu bar, stopping agents (also from
/// the global hotkey ⌃⌥⌘. while VMPane runs), and letting them act again, which only the app may do.
@MainActor
@Observable
final class AgentKillSwitch {
    private(set) var engaged = false
    private let paths: VMPanePaths
    @ObservationIgnored private var hotKey: EventHotKeyRef?
    @ObservationIgnored nonisolated(unsafe) private static var current: AgentKillSwitch?

    init(paths: VMPanePaths) {
        self.paths = paths
        // The policy key comes with a released switch; from then on a missing switch file means engaged.
        _ = PolicyKeyFile(paths: paths).key(create: true)
        refresh()
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                self?.refresh()
            }
        }
    }

    func refresh() {
        engaged = KillSwitch.isEngaged(paths: paths)
    }

    func stopAgents() {
        try? KillSwitch.engage(paths: paths)
        refresh()
    }

    func letAgentsAct() {
        try? KillSwitch.release(paths: paths)
        refresh()
    }

    /// ⌃⌥⌘. stops every agent, wherever VMPane's windows are.
    func registerHotKey() {
        Self.current = self
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, _ in
                MainActor.assumeIsolated { AgentKillSwitch.current?.stopAgents() }
                return noErr
            }, 1, &spec, nil, nil)
        let id = EventHotKeyID(signature: OSType(0x564D_5041), id: 1)  // "VMPA"
        RegisterEventHotKey(
            UInt32(kVK_ANSI_Period), UInt32(cmdKey | optionKey | controlKey), id, GetApplicationEventTarget(), 0, &hotKey)
    }
}

/// The kill switch in the menu bar extra.
struct AgentKillSwitchMenu: View {
    let killSwitch: AgentKillSwitch

    var body: some View {
        if killSwitch.engaged {
            Text("AI agents are stopped")
            Button("Let AI Agents Act Again") { killSwitch.letAgentsAct() }
        } else {
            Button("Stop All AI Agents  ⌃⌥⌘.") { killSwitch.stopAgents() }
        }
    }
}
