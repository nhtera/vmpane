import SwiftUI
import VMPaneCore
import VMPaneMCP

/// VMPane ▸ Settings ▸ AI Agents: stopping and allowing agents, your own terminal use, and adding VMPane to AI
/// clients. What each VM allows agents is in that VM's settings.
struct AgentsPreferences: View {
    let paths: VMPanePaths
    let killSwitch: AgentKillSwitch
    @State private var operatorGranted = false
    @State private var change: ClientConfigWriter.Change?
    @State private var client: ClientConfigWriter.Client?
    @State private var message: String?

    private var vmpane: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/vmpane") }

    var body: some View {
        Form {
            Section {
                if killSwitch.engaged {
                    Label("AI agents are stopped.", systemImage: "hand.raised.fill").foregroundStyle(.orange)
                    Button("Let AI Agents Act Again") { killSwitch.letAgentsAct() }
                } else {
                    Button("Stop All AI Agents") { killSwitch.stopAgents() }
                }
            } header: {
                Text("Kill switch")
            } footer: {
                Text("Also in the menu bar, with ⌃⌥⌘. while VMPane runs, and as vmpane mcp kill in a terminal.")
            }
            Section {
                Toggle("Let my own vmpane at a terminal control any VM", isOn: $operatorGranted)
                    .onChange(of: operatorGranted) { _, granted in
                        try? granted ? OperatorGrant.grant(paths: paths) : OperatorGrant.revoke(paths: paths)
                    }
            } header: {
                Text("Your terminal")
            } footer: {
                Text("vmpane run by you at a terminal then works whatever a VM allows agents. Scripts and agents stay bound.")
            }
            Section("Add VMPane to an AI client") {
                ForEach(ClientConfigWriter.Client.allCases, id: \.self) { which in
                    HStack {
                        Text(Self.name(which))
                        Spacer()
                        Button("Show the Change…") { show(which) }
                    }
                }
                if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
        .onAppear { operatorGranted = OperatorGrant.isGranted(paths: paths) }
        .sheet(item: $client) { which in
            ClientConfigSheet(client: which, change: change) { apply(which) }
        }
    }

    static func name(_ client: ClientConfigWriter.Client) -> String {
        switch client {
        case .claude: "Claude Code"
        case .codex: "Codex CLI"
        case .gemini: "Gemini CLI"
        }
    }

    private func show(_ which: ClientConfigWriter.Client) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        change = try? ClientConfigWriter.change(for: which, vmpane: vmpane, home: home, claudeOnPath: false)
        client = which
    }

    private func apply(_ which: ClientConfigWriter.Client) {
        guard let change, change.file != nil else { return }
        do {
            let backup = try ClientConfigWriter.apply(change)
            message =
                "\(Self.name(which)): updated \(change.file?.lastPathComponent ?? "")"
                + (backup.map { " (backup: \($0.lastPathComponent))" } ?? "")
        } catch {
            message = "\(Self.name(which)): \(error.localizedDescription)"
        }
        client = nil
    }
}

extension ClientConfigWriter.Client: @retroactive Identifiable {
    public var id: String { rawValue }
}

/// What adding VMPane changes for a client, before it is made.
private struct ClientConfigSheet: View {
    let client: ClientConfigWriter.Client
    let change: ClientConfigWriter.Change?
    let apply: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add VMPane to \(AgentsPreferences.name(client))").font(.headline)
            if let change, let after = change.after, let file = change.file {
                Text("\(file.path) will become (the old file is kept as a backup):").font(.callout)
                ScrollView {
                    Text(after).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 220)
                .background(.quaternary.opacity(0.3))
            } else {
                Text(change?.summary ?? "Cannot read this client's settings.").font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                if change?.file != nil {
                    Button("Make This Change", action: apply).keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 560)
    }
}
