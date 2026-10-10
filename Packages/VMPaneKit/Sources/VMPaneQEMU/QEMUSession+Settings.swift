import Foundation
import VMPaneCore

/// Settings applied to the running VM.
extension QEMUSession {
    /// Port forward changes become slirp rule changes on the running NIC (rules built only from validated
    /// parts, Red Team #13). Returns the paths in effect: all the port-forward paths when every change applied.
    func applyLive(_ config: VMConfigV1, paths: [String]) async -> Set<String> {
        let forwardPaths = paths.filter { $0.hasPrefix("portForwards") }
        guard let current = running, !forwardPaths.isEmpty, config.network.contains(where: { $0.mode == .nat }) else { return [] }
        var wanted: [String] = []
        for rule in config.portForwards {
            guard let forward = try? QEMUArgvBuilder.hostForward(rule) else { return [] }
            wanted.append(forward)
        }
        var ok = true
        for rule in forwards where !wanted.contains(rule) {
            // hostfwd_remove takes the host side only: "tcp:127.0.0.1:8080".
            let host = String(rule.prefix { $0 != "-" })
            // Success prints "host forwarding rule for … removed".
            if await hmp(current, "hostfwd_remove net0 \(host)", succeeded: { $0.hasSuffix("removed") }) {
                forwards.removeAll { $0 == rule }
            } else {
                ok = false
            }
        }
        for rule in wanted where !forwards.contains(rule) {
            if await hmp(current, "hostfwd_add net0 \(rule)", succeeded: \.isEmpty) { forwards.append(rule) } else { ok = false }
        }
        return ok ? Set(forwardPaths) : []
    }

    /// An HMP command. HMP reports success and failure as text; `succeeded` judges it.
    private func hmp(_ current: Running, _ command: String, succeeded: (String) -> Bool) async -> Bool {
        guard let output = try? await current.qmp.execute("human-monitor-command", ["command-line": .string(command)]) else { return false }
        let text = output.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard succeeded(text) else {
            Self.log.error("\(command, privacy: .public): \(text, privacy: .public)")
            return false
        }
        return true
    }
}
