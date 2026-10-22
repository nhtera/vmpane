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

    /// What to ask about `request`, if anything.
    func confirmation(for request: RPCRequest, _ caller: CallerIdentity) -> ConfirmationRequest? {
        guard caller.identity != .ui, caller.identity != .operator, config.mcp.confirmExec else { return nil }
        let who = Self.who(caller)
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

    /// The agent as the person is told about it. The client names itself: one line, printable, short, so it cannot
    /// pose as VMPane's own text.
    static func who(_ caller: CallerIdentity) -> String {
        let claimed = caller.claimedClient?.replacingOccurrences(of: " (claimed)", with: "") ?? ""
        let printable = String(String.UnicodeScalarView(claimed.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }))
            .trimmingCharacters(in: .whitespaces).prefix(40)
        return printable.isEmpty ? "An AI agent" : "“\(printable)” (an AI agent)"
    }

    /// What an agent's call must pass after the policy, in order: input that travels with a confirmed command,
    /// the person's answer, the session's undo snapshot, and the kill switch and the agent's connection once more
    /// (both waits can be long, and agents may have been stopped meanwhile: a call the switch stopped stays stopped,
    /// even when the app has released the switch since).
    func agentChecks(_ request: RPCRequest, _ caller: CallerIdentity) async -> RPCError? {
        guard caller.identity != .ui else { return nil }
        let admitted = agentGeneration
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
        if agentsStopped(since: admitted, caller) {
            return RPCError(.policyDenied, "AI agents are stopped (VMPane's kill switch)")
        }
        return nil
    }

    /// Asks, one question at a time and never while agents are stopped, with the timeout; false when nobody
    /// can answer. At the timeout the question is closed and the answer is no, whether or not the presenter
    /// gives up (a modal dialog does not end when its task is cancelled).
    func ask(_ question: ConfirmationRequest) async -> Bool {
        guard let presenter = confirmationPresenter else { return false }
        while confirming { try? await Task.sleep(for: .milliseconds(100)) }
        guard !killSwitchEngaged else { return false }
        confirming = true
        defer { confirming = false }
        // The person's answer, or nil at the timeout: whichever comes first.
        let (answers, answer) = AsyncStream.makeStream(of: Bool?.self, bufferingPolicy: .bufferingNewest(2))
        let asking = Task { answer.yield(await presenter(question)) }
        let timeout = confirmationTimeout
        let timing = Task {
            try? await Task.sleep(for: timeout)
            answer.yield(nil)
        }
        var first = answers.makeAsyncIterator()
        let given = await first.next() ?? nil
        timing.cancel()
        answer.finish()
        if given == nil {
            asking.cancel()
            await confirmationDismiss?()
        }
        return given ?? false
    }
}
