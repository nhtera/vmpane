import SwiftUI
import VMPaneCore

/// What AI agents (MCP clients, scripts using vmpane without a terminal) may do with this VM. Off by default;
/// only the app changes it. Your own vmpane at a terminal is not bound by it once you granted operator.
struct AgentPolicySection: View {
    @Binding var mcp: Extensible<MCPConfig>
    @Binding var clipboardAllowWithAgents: Bool
    let tampered: Bool
    let writableShares: Bool

    var body: some View {
        Section("AI agents") {
            if tampered {
                Label(
                    "Agent access was changed outside VMPane, so it is off. Choose a level to set it again.",
                    systemImage: "exclamationmark.shield"
                )
                .foregroundStyle(.orange)
            }
            Picker("Access", selection: $mcp.policy) {
                ForEach(PolicyLevel.allCases, id: \.self) { level in Text(Self.title(level)).tag(level) }
            }
            Text(Self.explanation(mcp.policy)).font(.caption).foregroundStyle(.secondary)
            if mcp.policy != .off {
                Toggle("Ask before an agent runs a command", isOn: $mcp.confirmExec)
                Toggle("Snapshot before each agent session", isOn: $mcp.autoSnapshot)
                Toggle("Record typed text in the activity log", isOn: $mcp.auditTypedText)
                Toggle("Let agents read and set the clipboard", isOn: $clipboardAllowWithAgents)
                if mcp.policy >= .exec && writableShares {
                    Label("Agents running commands can change the folders this VM shares.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
        }
    }

    static func title(_ level: PolicyLevel) -> String {
        switch level {
        case .off: "Off"
        case .observe: "Look only"
        case .control: "Use the screen and keyboard"
        case .exec: "Run commands"
        case .admin: "Full control"
        }
    }

    static func explanation(_ level: PolicyLevel) -> String {
        switch level {
        case .off: "Agents cannot see this VM."
        case .observe: "Agents can see its state and screenshots."
        case .control: "Agents can also click, type, start, pause and snapshot it."
        case .exec: "Agents can also run commands as the logged-in user and copy files in and out."
        case .admin: "Agents can also run commands as administrator, shut it down and delete snapshots."
        }
    }
}
