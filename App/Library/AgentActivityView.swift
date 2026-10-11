import SwiftUI
import VMPaneCore

/// What AI agents (and scripts) asked of this VM lately, from its audit log: when, who, what, and whether it
/// was allowed. Refusals stand out.
struct AgentActivityView: View {
    let bundle: URL
    @State private var entries: [AuditEntry] = []

    var body: some View {
        Section("Agent activity") {
            if entries.isEmpty {
                Text("No agent has used this VM.").foregroundStyle(.secondary)
            }
            ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                HStack(alignment: .firstTextBaseline) {
                    Image(
                        systemName: entry.result == "denied"
                            ? "hand.raised.fill" : entry.result == "ok" ? "checkmark.circle" : "xmark.circle"
                    )
                    .foregroundStyle(entry.result == "denied" ? .orange : entry.result == "ok" ? .green : .red)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(entry.client ?? entry.identity): \(entry.method)").font(.callout)
                        Text([Self.time(entry.timestamp), entry.reason].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
        .task(id: bundle) {
            while !Task.isCancelled {
                let log = AuditLog(url: bundle.appendingPathComponent("logs/mcp-audit.jsonl"))
                entries = await Task.detached { log.recent(limit: 30) }.value
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    static func time(_ timestamp: String) -> String? {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return parser.date(from: timestamp)?.formatted(date: .abbreviated, time: .standard)
    }
}
