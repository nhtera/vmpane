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
    public func setConfirmationPresenter(_ presenter: @escaping @Sendable (ConfirmationRequest) async -> Bool) {
        confirmationPresenter = presenter
    }

    static let confirmationTimeout: Duration = .seconds(60)

    /// What to ask about `request`, if anything.
    func confirmation(for request: RPCRequest, _ caller: CallerIdentity) -> ConfirmationRequest? {
        guard caller.identity != .ui, caller.identity != .operator, config.mcp.confirmExec else { return nil }
        let who = caller.claimedClient?.replacingOccurrences(of: " (claimed)", with: "") ?? "An AI agent"
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
            return ConfirmationRequest(title: "\(who) wants to run a command\(admin) in \(config.name)", detail: command)
        case ControlMethod.vmSnapshotRestore.rawValue:
            return ConfirmationRequest(
                title: "\(who) wants to restore a snapshot of \(config.name)", detail: "What changed since the snapshot will be lost.")
        case ControlMethod.vmStop.rawValue, ControlMethod.vmSnapshotDelete.rawValue, ControlMethod.helperShutdown.rawValue:
            return ConfirmationRequest(title: "\(who) wants to \(request.method) \(config.name)", detail: request.method)
        default:
            return nil
        }
    }

    /// Asks, with the timeout; false when nobody can answer.
    func ask(_ question: ConfirmationRequest) async -> Bool {
        guard let presenter = confirmationPresenter else { return false }
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
