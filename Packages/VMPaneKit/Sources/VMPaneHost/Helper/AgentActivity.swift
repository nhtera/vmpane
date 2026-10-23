import Foundation
import VMPaneControl
import VMPaneCore

/// What AI agents are doing on this VM, for the person at the Mac (the VM window's HUD, the library, the menu bar):
/// derived from the requests they make (the audit path) and the person's Take over. A Take over refuses every
/// agent request that changes anything, and stops a batch or typing between pieces, until the person resumes.
struct AgentActivityState: Sendable {
    struct Action: Sendable, Equatable {
        let client: String
        let method: String
        let ok: Bool
        let when: Date
    }

    /// Newest first.
    var recent: [Action] = []
    var takenOver = false
    static let kept = 10
    /// An agent's last request this recent: it is acting.
    static let acting: TimeInterval = 10
}

extension HelperController {
    static let takenOverReason = "The person at the Mac took over this VM. Wait, then retry."

    /// After every agent request (audited): what it did, for the HUD. A repeat of the newest (screenshot polling)
    /// replaces it, so the strip keeps what differs.
    func noteAgentAction(_ request: RPCRequest, _ caller: CallerIdentity, ok: Bool) {
        guard caller.identity != .ui, request.method != ControlMethod.helperHello.rawValue else { return }
        let action = AgentActivityState.Action(client: Self.clientName(caller), method: request.method, ok: ok, when: Date())
        var recent = activity.recent
        if let newest = recent.first, newest.client == action.client, newest.method == action.method { recent.removeFirst() }
        activity.recent = Array(([action] + recent).prefix(AgentActivityState.kept))
        broadcastAgentActivity()
    }

    /// The name an agent gave itself, made safe to show as VMPane's own text (`who`); its kind when it gave none.
    static func clientName(_ caller: CallerIdentity) -> String {
        printableName(caller) ?? (caller.identity == .operator ? "Your vmpane command" : "An AI agent")
    }

    /// Whether the person's Take over holds `caller` back from `method`: an agent's request that changes anything,
    /// or reads the guest's clipboard (the person may be copying secrets now). Never the app, nor the person's own
    /// operator CLI.
    func heldByTakeOver(_ method: String, _ caller: CallerIdentity) -> Bool {
        activity.takenOver && caller.identity != .ui && caller.identity != .operator
            && (!Self.readOnlyMethods.contains(method) || method == ControlMethod.vmClipboardRead.rawValue)
    }

    /// Why an agent's request admitted at generation `admitted` must not go on after a wait: agents were stopped
    /// (the kill switch, the stronger), or the person took over; nil when it may.
    func agentStopRefusal(since admitted: Int, _ caller: CallerIdentity, method: String) -> RPCError? {
        if killSwitchEngaged, caller.identity != .ui { return RPCError(.policyDenied, Self.stoppedReason) }
        if heldByTakeOver(method, caller) { return RPCError(.takenOver, Self.takenOverReason) }
        if agentsStopped(since: admitted, caller, orGone: false) { return RPCError(.policyDenied, Self.stoppedReason) }
        return nil
    }

    /// `agentStopRefusal` for `owner`'s request (nil: the app's own), thrown.
    func checkStillAdmitted(since admitted: Int, _ owner: ControlConnection?, _ method: ControlMethod) throws {
        if let owner, let refusal = agentStopRefusal(since: admitted, identity(of: owner), method: method.rawValue) { throw refusal }
    }

    /// `vm.agent.activity`: who acts, at what level, what it is doing and did last, and whether the person took over.
    func agentActivity(now: Date = Date()) -> JSONValue {
        let last = activity.recent.first
        let acting = last.map { now.timeIntervalSince($0.when) < AgentActivityState.acting } ?? false
        var result: [String: JSONValue] = [
            "acting": .bool(acting && !activity.takenOver && !killSwitchEngaged), "takenOver": .bool(activity.takenOver),
            "stopped": .bool(killSwitchEngaged), "level": .string(effectivePolicy().level.rawValue),
            "recent": .array(
                activity.recent.prefix(3).map {
                    [
                        "method": .string($0.method), "what": .string(Self.describe($0.method)), "ok": .bool($0.ok),
                        "at": .string($0.when.formatted(.iso8601)),
                    ]
                }),
        ]
        if let last {
            result["client"] = .string(last.client)
            result["current"] = .string(Self.describe(last.method))
        }
        return .object(result)
    }

    /// To the app's connections only: an agent does not learn what other agents do (as with the query, uiOnly).
    func broadcastAgentActivity() {
        guard let server else { return }
        let activity = agentActivity()
        for connection in server.activeConnections where identities[ObjectIdentifier(connection)]?.identity == .ui {
            connection.notify(topic: "vm", method: ControlNotification.agentActivity.rawValue, params: activity)
        }
    }

    /// `vm.agent.takeOver`, `vm.agent.resume`, `vm.agent.stop` (the app only) and `vm.agent.activity`.
    func agentActivityRequest(_ method: String) async -> Result<JSONValue, RPCError> {
        switch ControlMethod(rawValue: method) {
        case .vmAgentTakeOver?:
            activity.takenOver = true  // a batch or typing under way stops at its next piece (`agentInputStopped`)
            if confirming { await confirmationDismiss?() }  // an open question is a no
            await releaseHeldInput()  // the person types next: no Shift or button an agent left down
            Self.log.notice("the person took over from AI agents")
        case .vmAgentResume?:
            activity.takenOver = false
            Self.log.notice("the person let AI agents act again")
        case .vmAgentStop?:
            // Stopped until Resume: an agent's client reconnects at its next call, and would go on.
            activity.takenOver = true
            if confirming { await confirmationDismiss?() }
            await stopAgents()
            Self.log.notice("the person stopped AI agents on this VM")
        default:
            break
        }
        broadcastAgentActivity()
        return .success(agentActivity())
    }

    /// The HUD's words for what a request does.
    static func describe(_ method: String) -> String {
        switch ControlMethod(rawValue: method) {
        case .vmInputText?: "typing"
        case .vmInputKey?: "pressing keys"
        case .vmInputPointer?: "using the mouse"
        case .vmInputScroll?: "scrolling"
        case .vmInputBatch?: "using the keyboard and mouse"
        case .vmScreenshot?: "looking at the screen"
        case .vmScreenRead?: "reading the screen"
        case .agentExec?, .agentExecInput?, .agentExecSignal?: "running a command"
        case .agentFilePush?, .agentFilePull?, .vmFilesDrop?: "copying files"
        case .vmSnapshotCreate?: "taking a snapshot"
        case .vmSnapshotRestore?: "restoring a snapshot"
        case .vmSnapshotDelete?: "deleting a snapshot"
        case .vmStart?, .vmResume?: "starting the VM"
        case .vmStop?, .vmSuspend?, .vmPause?: "stopping the VM"
        case .vmSignIn?: "signing in"
        case .vmClipboardRead?, .vmClipboardWrite?: "using the clipboard"
        case .vmSettingsApply?: "changing settings"
        default: "working"
        }
    }
}
