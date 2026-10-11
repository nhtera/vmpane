import Foundation
import Testing

@testable import VMPaneMCP

private let vmpane = URL(fileURLWithPath: "/Applications/VMPane.app/Contents/Helpers/vmpane")

@Test func codexGetsItsTableOtherSettingsStay() {
    let existing = "model = \"o4\"\n\n[mcp_servers.other]\ncommand = \"x\"\n"
    let added = ClientConfigWriter.codexTOML(existing, vmpane: vmpane)
    #expect(added.hasPrefix(existing))
    #expect(added.contains("[mcp_servers.vmpane]\ncommand = \"/Applications/VMPane.app/Contents/Helpers/vmpane\"\nargs = [\"mcp\"]\n"))
    let moved = ClientConfigWriter.codexTOML(added, vmpane: URL(fileURLWithPath: "/new/vmpane"))
    #expect(moved.components(separatedBy: "[mcp_servers.vmpane]").count == 2, "replaced, not added twice")
    #expect(moved.contains("command = \"/new/vmpane\"") && moved.contains("[mcp_servers.other]"))
    #expect(ClientConfigWriter.codexTOML("", vmpane: vmpane).hasPrefix("[mcp_servers.vmpane]"))
    #expect(ClientConfigWriter.tomlString(#"a"b\c"#) == #""a\"b\\c""#)
}

@Test func geminiGetsItsServerOtherSettingsStay() throws {
    let existing = #"{"theme": "dark", "mcpServers": {"other": {"command": "x"}}}"#
    let added = try ClientConfigWriter.geminiJSON(existing, vmpane: vmpane)
    let object = try #require(try JSONSerialization.jsonObject(with: Data(added.utf8)) as? [String: Any])
    let servers = try #require(object["mcpServers"] as? [String: Any])
    #expect(object["theme"] as? String == "dark" && servers["other"] != nil)
    #expect((servers["vmpane"] as? [String: Any])?["args"] as? [String] == ["mcp"])
    #expect(throws: (any Error).self) { try ClientConfigWriter.geminiJSON("[1]", vmpane: vmpane) }
}

@Test func applyingBacksUpTheOldFile() throws {
    let home = URL(fileURLWithPath: "/tmp/vp-cfg-\(UUID().uuidString.prefix(8))")
    defer { try? FileManager.default.removeItem(at: home) }
    let first = try ClientConfigWriter.change(for: .gemini, vmpane: vmpane, home: home, claudeOnPath: false)
    #expect(first.before == nil)
    #expect(try ClientConfigWriter.apply(first) == nil, "nothing to back up")
    let second = try ClientConfigWriter.change(for: .gemini, vmpane: URL(fileURLWithPath: "/other/vmpane"), home: home, claudeOnPath: false)
    let backup = try #require(try ClientConfigWriter.apply(second))
    #expect(try String(contentsOf: backup, encoding: .utf8) == first.after)
    let claude = try ClientConfigWriter.change(for: .claude, vmpane: vmpane, home: home, claudeOnPath: true)
    #expect(claude.command == ["claude", "mcp", "add", "--scope", "user", "vmpane", "--", vmpane.path, "mcp"])
}
