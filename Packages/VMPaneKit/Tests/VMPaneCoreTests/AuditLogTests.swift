import Foundation
import Testing

@testable import VMPaneCore

private func temporaryLog(maxBytes: Int = AuditLog.maxBytes) -> AuditLog {
    AuditLog(url: URL(fileURLWithPath: "/tmp/vp-audit-\(UUID().uuidString.prefix(8))/logs/mcp-audit.jsonl"), maxBytes: maxBytes)
}

@Test func auditLinesAreAppendedAsJSON() throws {
    let log = temporaryLog()
    defer { try? FileManager.default.removeItem(at: log.url.deletingLastPathComponent().deletingLastPathComponent()) }
    try log.append(
        .init(identity: "cli", kind: "mcp", tool: "vm_exec", method: "agent.exec", args: ["argv": ["uname"]], policy: "exec", result: "ok"))
    try log.append(.init(identity: "cli", kind: "cli", method: "vm.stop", policy: "control", result: "denied", reason: "needs admin"))
    let lines = try String(contentsOf: log.url, encoding: .utf8).split(separator: "\n")
    #expect(lines.count == 2)
    let first = try JSONDecoder().decode(AuditEntry.self, from: Data(lines[0].utf8))
    #expect(first.method == "agent.exec" && first.tool == "vm_exec" && first.result == "ok" && first.timestamp.hasSuffix("Z"))
    #expect(lines[1].contains(#""reason":"needs admin""#))
    #expect(log.recent(limit: 5).map(\.method) == ["vm.stop", "agent.exec"], "newest first")
    let mode = try FileManager.default.attributesOfItem(atPath: log.url.path)[.posixPermissions] as? Int
    #expect(mode == 0o600)
}

@Test func auditLogsRotateAndKeepFive() throws {
    let log = temporaryLog(maxBytes: 400)
    defer { try? FileManager.default.removeItem(at: log.url.deletingLastPathComponent().deletingLastPathComponent()) }
    for index in 0..<40 {
        try log.append(
            .init(identity: "cli", kind: "cli", method: "vm.info", args: ["n": .int(Int64(index))], policy: "observe", result: "ok"))
    }
    let names = try FileManager.default.contentsOfDirectory(atPath: log.url.deletingLastPathComponent().path).sorted()
    #expect(
        names == [
            "mcp-audit.jsonl", "mcp-audit.jsonl.1", "mcp-audit.jsonl.2", "mcp-audit.jsonl.3", "mcp-audit.jsonl.4", "mcp-audit.jsonl.5",
        ])
    #expect(try String(contentsOf: log.url, encoding: .utf8).contains(#""n":39"#), "the newest is in the current file")
}

@Test func secretsAreRecordedAsHashesOrNames() {
    let typed = AuditLog.recorded(method: "vm.input.text", params: ["text": "hunter2"], typedText: false)
    #expect(typed?["text"]?.stringValue?.hasPrefix("sha256:") == true && typed?["text"] != "hunter2")
    #expect(AuditLog.recorded(method: "vm.input.text", params: ["text": "ls"], typedText: true)?["text"] == "ls")
    let exec = AuditLog.recorded(method: "agent.exec", params: ["argv": ["env"], "env": ["TOKEN": "s3cret", "A": "b"]], typedText: false)
    #expect(exec?["env"] == ["A", "TOKEN"])
    let clip = AuditLog.recorded(method: "vm.clipboard.write", params: ["items": [["type": "text", "text": "pw"]]], typedText: true)
    guard case .array(let items)? = clip?["items"] else { Issue.record("no items"); return }
    #expect(items.first?["text"]?.stringValue?.hasPrefix("sha256:") == true)
    #expect(AuditLog.recorded(method: "agent.exec.input", params: ["execId": 1, "dataB64": "eA=="], typedText: false) == ["execId": 1])
}
