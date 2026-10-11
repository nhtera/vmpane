import CryptoKit
import Foundation
import VMPaneControl
import VMPaneCore

/// Who a control connection is, decided once from its code signature (`PeerClassifier`) and what the vmpane CLI
/// reported about itself in `helper.hello`.
struct CallerIdentity: Sendable {
    let identity: ClientIdentity
    /// For the audit log: ui, itest, operator, cli, automated.
    let label: String
    /// What the client says it is ("claude-code (claimed)").
    let claimedClient: String?
    let kind: String
    let session: String?
    weak var connection: ControlConnection?
}

/// The agent policy, enforced (Red Team #1): every request is checked against `ControlMethodPolicy` at the level
/// in effect for this VM (`PolicyIntegrity`); denials, and every call by a client that is not the app, go to the
/// VM's audit log before the answer.
extension HelperController {
    func identity(of connection: ControlConnection) -> CallerIdentity {
        if let known = identities[ObjectIdentifier(connection)], known.connection === connection { return known }
        let caller = Self.caller(classifier.classify(connection.peer), hello: nil, connection: connection)
        remember(caller, for: connection)
        return caller
    }

    /// `helper.hello` names the client; the vmpane CLI also says whether it passed its operator checks, which only
    /// a peer signed as the CLI may claim.
    func noteHello(_ params: JSONValue?, from connection: ControlConnection) {
        remember(Self.caller(classifier.classify(connection.peer), hello: params, connection: connection), for: connection)
    }

    static func caller(_ kind: PeerClassifier.Kind, hello: JSONValue?, connection: ControlConnection) -> CallerIdentity {
        let client = hello?["client"]
        let claimed = client?["name"]?.stringValue.map { "\($0) (claimed)" }
        let clientKind = client?["kind"]?.stringValue ?? "unknown"
        let session = hello?["sessionId"]?.stringValue
        let (identity, label): (ClientIdentity, String) =
            switch kind {
            case .ui: (.ui, "ui")
            case .itest: (.ui, "itest")
            case .cli where client?["operator"] == true: (.operator, "operator")
            case .cli: (.automated, "cli")
            case .other: (.automated, "automated")
            }
        return CallerIdentity(
            identity: identity, label: label, claimedClient: claimed, kind: clientKind, session: session, connection: connection)
    }

    private func remember(_ caller: CallerIdentity, for connection: ControlConnection) {
        if identities.count > 256 { identities = identities.filter { $0.value.connection != nil } }
        identities[ObjectIdentifier(connection)] = caller
    }

    /// The policy that applies now (the saved level only with a valid tag).
    func effectivePolicy() -> PolicyIntegrity.Effective {
        if policyKey == nil { policyKey = PolicyKeyFile(paths: prepared.runFiles.paths).key(create: false) }
        return PolicyIntegrity.effective(config, key: policyKey)
    }

    /// Nil when `caller` may make `request`; else the refusal (audited).
    func authorize(_ request: RPCRequest, _ caller: CallerIdentity) -> RPCError? {
        let policy = effectivePolicy()
        if killSwitchEngaged, caller.identity != .ui, request.method != ControlMethod.mcpDisableAll.rawValue,
            request.method != ControlMethod.helperHello.rawValue
        {
            let reason = "AI agents are stopped (VMPane's kill switch); the app can let them act again"
            writeAudit(request, caller, policy: policy.level, AuditOutcome(result: "denied", reason: reason, durationMs: nil))
            return RPCError(.policyDenied, reason)
        }
        let decision = PolicyEnforcer.decide(
            method: request.method, params: request.params, level: policy.level, identity: caller.identity,
            context: PolicyContext(clipboardAllowWithAgents: policy.clipboardAllowWithAgents))
        guard case .deny(let reason) = decision else { return nil }
        writeAudit(request, caller, policy: policy.level, AuditOutcome(result: "denied", reason: reason, durationMs: nil))
        return RPCError(.policyDenied, reason)
    }

    func audit(
        _ request: RPCRequest, _ caller: CallerIdentity, result: Result<JSONValue, RPCError>, since started: ContinuousClock.Instant
    ) {
        let elapsed = ContinuousClock.now - started
        let milliseconds = Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
        var reason: String?
        if case .failure(let error) = result { reason = error.message }
        writeAudit(
            request, caller, policy: effectivePolicy().level,
            AuditOutcome(result: reason == nil ? "ok" : "error", reason: reason, durationMs: milliseconds))
    }

    private struct AuditOutcome {
        let result: String
        let reason: String?
        let durationMs: Int?
    }

    private func writeAudit(_ request: RPCRequest, _ caller: CallerIdentity, policy: PolicyLevel, _ outcome: AuditOutcome) {
        let entry = AuditEntry(
            session: caller.session, client: caller.claimedClient, identity: caller.label, kind: caller.kind, method: request.method,
            args: AuditLog.recorded(method: request.method, params: request.params, typedText: config.mcp.auditTypedText),
            policy: policy.rawValue, result: outcome.result, reason: outcome.reason, durationMs: outcome.durationMs)
        do {
            try auditLog.append(entry)
        } catch {
            Self.log.error("the audit log cannot be written: \(String(describing: error), privacy: .public)")
        }
    }
}
