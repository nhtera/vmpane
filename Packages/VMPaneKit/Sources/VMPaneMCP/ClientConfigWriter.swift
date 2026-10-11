import Foundation

/// Adds VMPane's MCP server (`<vmpane> mcp`, stdio) to an AI client's configuration: what would change, and
/// writing it after a backup. Formats as the clients document them (Claude Code's `claude mcp add`; Codex CLI's
/// `~/.codex/config.toml` `[mcp_servers.<name>]`; Gemini CLI's `~/.gemini/settings.json` `mcpServers`).
public enum ClientConfigWriter {
    public enum Client: String, CaseIterable, Sendable {
        case claude, codex, gemini
    }

    /// One client's change: a file's new text (with its current one), or a command to run, plus how to say it.
    public struct Change: Sendable, Equatable {
        public let file: URL?
        public let before: String?
        public let after: String?
        public let command: [String]?
        /// For people: the snippet or the command.
        public let summary: String
    }

    public static func change(for client: Client, vmpane: URL, home: URL, claudeOnPath: Bool) throws -> Change {
        switch client {
        case .claude:
            let command = ["claude", "mcp", "add", "--scope", "user", "vmpane", "--", vmpane.path, "mcp"]
            if claudeOnPath { return Change(file: nil, before: nil, after: nil, command: command, summary: command.joined(separator: " ")) }
            let snippet = """
                {
                  "mcpServers": {
                    "vmpane": { "command": "\(vmpane.path)", "args": ["mcp"] }
                  }
                }
                """
            return Change(
                file: nil, before: nil, after: nil, command: nil,
                summary: "Add this to your project's .mcp.json (claude is not on your PATH):\n\(snippet)")
        case .codex:
            let file = home.appendingPathComponent(".codex/config.toml")
            let before = try? String(contentsOf: file, encoding: .utf8)
            let after = codexTOML(before ?? "", vmpane: vmpane)
            return Change(file: file, before: before, after: after, command: nil, summary: "\(file.path):\n[mcp_servers.vmpane] …")
        case .gemini:
            let file = home.appendingPathComponent(".gemini/settings.json")
            let before = try? String(contentsOf: file, encoding: .utf8)
            let after = try geminiJSON(before, vmpane: vmpane)
            return Change(file: file, before: before, after: after, command: nil, summary: "\(file.path):\nmcpServers.vmpane …")
        }
    }

    /// `config.toml` with a `[mcp_servers.vmpane]` table (replacing an earlier one; everything else untouched).
    static func codexTOML(_ text: String, vmpane: URL) -> String {
        let table = "[mcp_servers.vmpane]\ncommand = \(tomlString(vmpane.path))\nargs = [\"mcp\"]\n"
        var lines = text.components(separatedBy: "\n")
        if let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "[mcp_servers.vmpane]" }) {
            var end = start + 1
            while end < lines.count, !lines[end].trimmingCharacters(in: .whitespaces).hasPrefix("[") { end += 1 }
            lines.replaceSubrange(start..<end, with: table.components(separatedBy: "\n").dropLast() + [""])
            return lines.joined(separator: "\n")
        }
        let base = text.isEmpty || text.hasSuffix("\n\n") ? text : text.hasSuffix("\n") ? text + "\n" : text + "\n\n"
        return base + table
    }

    static func tomlString(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// `settings.json` with `mcpServers.vmpane` (other settings and servers kept).
    static func geminiJSON(_ text: String?, vmpane: URL) throws -> String {
        var settings: [String: Any] = [:]
        if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
                throw CocoaError(.fileReadCorruptFile)
            }
            settings = object
        }
        var servers = settings["mcpServers"] as? [String: Any] ?? [:]
        servers["vmpane"] = ["command": vmpane.path, "args": ["mcp"]]
        settings["mcpServers"] = servers
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return (String(bytes: data, encoding: .utf8) ?? "{}") + "\n"
    }

    /// Writes the change's file, keeping the old one as `<name>.vmpane-backup-<time>`; returns the backup.
    @discardableResult
    public static func apply(_ change: Change, now: Date = Date()) throws -> URL? {
        guard let file = change.file, let after = change.after else { return nil }
        let fm = FileManager.default
        try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        var backup: URL?
        if fm.fileExists(atPath: file.path) {
            let stamp = Int(now.timeIntervalSince1970)
            let copy = file.deletingLastPathComponent().appendingPathComponent("\(file.lastPathComponent).vmpane-backup-\(stamp)")
            try fm.copyItem(at: file, to: copy)
            backup = copy
        }
        try Data(after.utf8).write(to: file, options: .atomic)
        return backup
    }
}
