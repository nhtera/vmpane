import Foundation
import VMPaneControl
import VMPaneCore

/// What an agent wants, for the person to allow or deny.
public struct ConfirmationRequest: Sendable, Equatable {
    /// "Claude Code wants to run a command in Ubuntu".
    public let title: String
    /// The command, or what is restored or deleted.
    public let detail: String
}

/// Asking before an agent runs a command, goes back to a snapshot, or does an admin action (`mcp.confirmExec`, on
/// by default). The helper app shows the question; no answer within a minute is a no, and so is a helper that
/// cannot ask.
extension HelperController {
    /// The helper app's way of asking (a dialog); nil: nobody can answer, so nothing is allowed.
    /// `dismiss` closes an open question at once (the kill switch).
    public func setConfirmationPresenter(
        _ presenter: @escaping @Sendable (ConfirmationRequest) async -> Bool, dismiss: @escaping @Sendable () async -> Void
    ) {
        confirmationPresenter = presenter
        confirmationDismiss = dismiss
    }

    static let confirmationTimeout: Duration = .seconds(60)

    /// What to ask about `request`, if anything.
    func confirmation(for request: RPCRequest, _ caller: CallerIdentity) -> ConfirmationRequest? {
        guard caller.identity != .ui, caller.identity != .operator, config.mcp.confirmExec else { return nil }
        // The client names itself: one line, printable, short, so it cannot pose as VMPane's own text.
        let claimed = caller.claimedClient?.replacingOccurrences(of: " (claimed)", with: "") ?? ""
        let printable = String(String.UnicodeScalarView(claimed.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }))
            .trimmingCharacters(in: .whitespaces).prefix(40)
        let who = printable.isEmpty ? "An AI agent" : "“\(printable)” (an AI agent)"
        let params = request.params
        switch request.method {
        case ControlMethod.agentExec.rawValue:
            let command =
                params?["shell"]?.stringValue
                ?? params?["argv"].map { value -> String in
                    guard case .array(let parts) = value else { return "" }
                    return parts.compactMap(\.stringValue).joined(separator: " ")
                } ?? "?"
            let admin = params?["as"] == "admin" ? " as administrator" : ""
            let input = params?["input"]?.stringValue.map { "\n\n— with this input —\n" + String($0.prefix(4096)) } ?? ""
            return ConfirmationRequest(title: "\(who) wants to run a command\(admin) in \(config.name)", detail: command + input)
        case ControlMethod.vmSnapshotRestore.rawValue:
            return ConfirmationRequest(
                title: "\(who) wants to restore a snapshot of \(config.name)", detail: "What changed since the snapshot will be lost.")
        case ControlMethod.vmStop.rawValue, ControlMethod.vmSnapshotDelete.rawValue, ControlMethod.helperShutdown.rawValue:
            return ConfirmationRequest(title: "\(who) wants to \(request.method) \(config.name)", detail: request.method)
        default:
            return nil
        }
    }

    /// What an agent's call must pass after the policy, in order: input that travels with a confirmed command,
    /// the person's answer, the session's undo snapshot, and the kill switch and the agent's connection once more
    /// (both waits can be long, and agents may have been stopped meanwhile).
    func agentChecks(_ request: RPCRequest, _ caller: CallerIdentity) async -> RPCError? {
        guard caller.identity != .ui else { return nil }
        if let refusal = hostPathRefusal(request) { return refusal }
        if caller.identity != .operator, config.mcp.confirmExec, request.method == ControlMethod.agentExec.rawValue,
            request.params?["stdin"] == true
        {
            return RPCError(
                .policyDenied,
                "with \"Ask before an agent runs a command\" on, a command's input goes with it "
                    + "(the input parameter), so the person sees it")
        }
        if let question = confirmation(for: request, caller), await !ask(question) {
            return RPCError(.policyDenied, "the person at this Mac did not allow it (\(question.title))")
        }
        if let refusal = await snapshotBeforeAgentChange(request, caller) { return refusal }
        if killSwitchEngaged || caller.connection == nil {
            return RPCError(.policyDenied, "AI agents are stopped (VMPane's kill switch)")
        }
        return nil
    }

    /// Asks, one question at a time and never while agents are stopped, with the timeout; false when nobody
    /// can answer.
    func ask(_ question: ConfirmationRequest) async -> Bool {
        guard let presenter = confirmationPresenter else { return false }
        while confirming { try? await Task.sleep(for: .milliseconds(100)) }
        guard !killSwitchEngaged else { return false }
        confirming = true
        defer { confirming = false }
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask { await presenter(question) }
            group.addTask {
                try? await Task.sleep(for: Self.confirmationTimeout)
                return false
            }
            let answer = await group.next() ?? false
            group.cancelAll()
            return answer
        }
    }
}
