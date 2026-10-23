import SwiftUI

/// The settings sheet's sections, in its sidebar's order: each with its title, icon and colour, and the settings
/// (config paths) it holds, so the sidebar can mark a section whose changes are pending or were refused.
public enum SettingsSection: String, CaseIterable, Identifiable, Sendable {
    case general, hardware, display, sharing, agents, network, portForwarding

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .general: "General"
        case .hardware: "Hardware"
        case .display: "Display"
        case .sharing: "Sharing"
        case .agents: "AI agents"
        case .network: "Network"
        case .portForwarding: "Port Forwarding"
        }
    }

    public var systemImage: String {
        switch self {
        case .general: "gearshape.fill"
        case .hardware: "cpu.fill"
        case .display: "display"
        case .sharing: "folder.fill"
        case .agents: "sparkles"
        case .network: "network"
        case .portForwarding: "arrow.left.arrow.right"
        }
    }

    var color: Color {
        switch self {
        case .general: .gray
        case .hardware: .blue
        case .display: .indigo
        case .sharing: .green
        case .agents: .purple
        case .network: .cyan
        case .portForwarding: .orange
        }
    }

    /// The config paths (or their prefixes) this section's rows edit.
    var paths: [String] {
        switch self {
        case .general: ["name"]
        case .hardware: ["cpu.", "memory."]
        case .display: ["display."]
        case .sharing: ["clipboard.mode", "clipboard.keepFormatting", "audio.", "shares"]
        case .agents: ["mcp.", "clipboard.allowWithAgents"]
        case .network: ["network."]
        case .portForwarding: ["portForwards"]
        }
    }

    /// The section that holds config path `path`.
    public static func holding(_ path: String) -> SettingsSection? {
        allCases.first { section in section.paths.contains { path == $0 || path.hasPrefix($0.hasSuffix(".") ? $0 : $0 + ".") } }
    }
}
