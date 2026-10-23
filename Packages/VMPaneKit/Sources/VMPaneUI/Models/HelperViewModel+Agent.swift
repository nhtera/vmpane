import Foundation
import SwiftUI
import VMPaneControl
import VMPaneCore
import VMPaneHost

/// What AI agents are doing on a VM, as its helper says (`vm.agent.activity`).
public struct AgentActivity: Equatable, Sendable {
    public struct Action: Equatable, Sendable, Identifiable {
        /// Its place in `recent` (two actions may share a second and a description).
        public var id: Int
        public var what: String
        public var ok: Bool
        public var when: Date
    }

    public var acting: Bool
    public var takenOver: Bool
    /// VMPane's kill switch stopped every agent.
    public var stopped: Bool
    public var level: PolicyLevel
    public var client: String?
    /// What the agent is doing ("typing").
    public var current: String?
    /// Its last actions, newest first.
    public var recent: [Action]

    public init(_ json: JSONValue) {
        acting = json["acting"] == true
        takenOver = json["takenOver"] == true
        stopped = json["stopped"] == true
        level = json["level"]?.stringValue.flatMap(PolicyLevel.init(rawValue:)) ?? .off
        client = json["client"]?.stringValue
        current = json["current"]?.stringValue
        let parser = ISO8601DateFormatter()
        recent = (json["recent"]?.arrayValue ?? []).enumerated().map { index, item in
            Action(
                id: index, what: item["what"]?.stringValue ?? "", ok: item["ok"] != false,
                when: item["at"]?.stringValue.flatMap(parser.date(from:)) ?? Date())
        }
    }

    /// Something to show: an agent acts, acted lately, or the person took over.
    public var visible: Bool { acting || takenOver || !recent.isEmpty }
}

extension JSONValue {
    fileprivate var arrayValue: [JSONValue]? {
        if case .array(let items) = self { return items }
        return nil
    }
}

extension HelperViewModel {
    func refreshActivity() async {
        guard let reply = try? await channel.call(ControlMethod.vmAgentActivity.rawValue, params: nil, timeout: .seconds(5)) else {
            return
        }
        show(AgentActivity(reply))
    }

    /// Shows `activity`; an agent that stops acting is seen as idle a moment later (the helper says nothing then).
    func show(_ activity: AgentActivity) {
        let started = activity.acting && self.activity?.acting != true
        let tookOver = activity.takenOver && self.activity?.takenOver != true
        let resumed = !activity.takenOver && self.activity?.takenOver == true
        withAnimation(.easeInOut(duration: 0.2)) { self.activity = activity }
        if started, let client = activity.client {
            AccessibilityNotification.Announcement("\(client) is using \(name ?? "the VM")").post()
        }
        if tookOver, activity.stopped {
            AccessibilityNotification.Announcement("AI agents are stopped in \(name ?? "the VM")").post()
        } else if tookOver {
            AccessibilityNotification.Announcement("You took over \(name ?? "the VM") from AI agents").post()
        }
        if resumed { AccessibilityNotification.Announcement("AI agents can act on \(name ?? "the VM") again").post() }
        activityRefresh?.cancel()
        guard activity.acting else { return }
        activityRefresh = Task { [weak self] in
            try? await Task.sleep(for: .seconds(11))
            guard !Task.isCancelled else { return }
            await self?.refreshActivity()
        }
    }

    /// Take over: agents' requests that change anything are refused until Resume.
    public func takeOver() async { await agentControl(.vmAgentTakeOver) }

    public func resumeAgents() async { await agentControl(.vmAgentResume) }

    /// Ends what agents are doing here: their commands, apps and transfers, and their connections.
    public func stopAgents() async { await agentControl(.vmAgentStop) }

    private func agentControl(_ method: ControlMethod) async {
        do {
            show(AgentActivity(try await channel.call(method.rawValue, params: nil, timeout: .seconds(10))))
        } catch {
            lastError = String(describing: error)
        }
    }

    /// The person pressed a key or clicked in the VM's window (real input only: agents' input never passes the
    /// window): while an agent acts, that is a Take over.
    public func personActed() {
        guard let activity, activity.acting, !activity.takenOver else { return }
        Task { await takeOver() }
    }

    // MARK: - Approvals in the window

    /// Asks the person in the VM's window (`ApprovalSheet`); false when they deny or the question is dismissed.
    public func presentApproval(_ question: ConfirmationRequest) async -> Bool {
        dismissApproval()
        return await withCheckedContinuation { continuation in
            approvalAnswer = continuation
            approval = question
        }
    }

    public func answerApproval(_ allowed: Bool) {
        approval = nil
        approvalAnswer?.resume(returning: allowed)
        approvalAnswer = nil
    }

    /// Closes an open question: a no.
    public func dismissApproval() {
        guard approvalAnswer != nil || approval != nil else { return }
        answerApproval(false)
    }
}
