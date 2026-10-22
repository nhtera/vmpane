import SwiftUI
import VMPaneCore

/// What AI agents (MCP clients, scripts using vmpane without a terminal) may do with this VM. Off by default;
/// only the app changes it. Your own vmpane at a terminal is not bound by it once you granted operator.
struct AgentPolicySection: View {
    @Binding var mcp: Extensible<MCPConfig>
    @Binding var clipboardAllowWithAgents: Bool
    let tampered: Bool
    let writableShares: Bool
    /// The VM, for its kept sign-in password.
    let vm: UUID
    let name: String

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
                ForEach(PolicyLevel.allCases, id: \.self) { level in Text(level.title).tag(level) }
            }
            Text(mcp.policy.explanation).font(.caption).foregroundStyle(.secondary)
            if mcp.policy != .off {
                Toggle("Ask before an agent runs a command", isOn: $mcp.confirmExec)
                Toggle("Snapshot before each agent session", isOn: $mcp.autoSnapshot)
                Toggle("Record typed text in the activity log", isOn: $mcp.auditTypedText)
                Toggle("Let agents read and set the clipboard", isOn: $clipboardAllowWithAgents)
                if mcp.policy >= .control {
                    Toggle("Let agents sign in", isOn: signIn)
                    if mcp.signIn == true { SignInPasswordRow(vm: vm, name: name, askFirst: mcp.policy >= .exec) }
                }
                if mcp.policy >= .exec && writableShares {
                    Label("Agents running commands can change the folders this VM shares.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
        }
    }

    private var signIn: Binding<Bool> {
        Binding(get: { mcp.signIn == true }, set: { mcp.signIn = $0 ? true : nil })
    }
}

/// The guest password agents sign in with: saved at once (not with Apply) where only VMPane can read it, shown to no
/// one (the inspector's Copy Password gives it back to the person). Never your Mac's password: it is typed into the VM, whose screen the agent sees.
struct SignInPasswordRow: View {
    let vm: UUID
    let name: String
    let askFirst: Bool
    @State private var password = ""
    @State private var kept = false
    @State private var problem: String?

    private var store: GuestCredentialStore { GuestCredentials.store(paths: .standard()) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SecureField(kept ? "Password kept: enter a new one to replace it" : "The VM account's password", text: $password)
                Button("Save") { save() }.disabled(password.isEmpty)
                if kept { Button("Forget") { forget() } }
            }
            Text(
                "VMPane types it at the VM's login or lock screen; agents never see it. "
                    + (askFirst ? "You are asked each time. " : "") + "Use the VM's own password, never your Mac's."
            )
            .font(.caption).foregroundStyle(.secondary)
            if let problem { Text(problem).font(.caption).foregroundStyle(.red) }
        }
        .task { kept = store.has(vm) }
    }

    private func save() {
        do {
            try store.save(password, for: vm, name: name)
            password = ""
            kept = true
            problem = nil
        } catch {
            problem = "\(error)"
        }
    }

    private func forget() {
        do {
            try store.delete(for: vm)
            kept = false
            problem = nil
        } catch {
            problem = "\(error)"
        }
    }
}
