import Foundation
import VMPaneControl
import VMPaneCore

/// Undo for an agent session (Red Team #3, #8): before the first call of a session (one `vmpane mcp` process)
/// that changes anything, the VM is snapshotted (`origin: agentSession`): live when it runs and can, else a disk
/// snapshot (frozen through the agent on a running guest). When neither works the call is refused rather than run
/// without a way back. The last five agent snapshots are kept, and a live session's own never goes.
extension HelperController {
    /// Methods that change nothing.
    static let readOnlyMethods: Set<String> = [
        "helper.hello", "vm.info", "vm.screenshot", "vm.snapshot.list", "vm.settings.get", "vm.ports.list", "agent.status",
        "vm.clipboard.read", "events.subscribe", "mcp.disableAll",
    ]

    static let keptAgentSnapshots = 5

    /// Takes the session's snapshot before its first change; a refusal when that is not possible.
    func snapshotBeforeAgentChange(_ request: RPCRequest, _ caller: CallerIdentity) async -> RPCError? {
        guard caller.identity != .ui, let session = caller.session, config.mcp.autoSnapshot,
            !Self.readOnlyMethods.contains(request.method), agentSessions[session] == nil
        else { return nil }
        let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
        let name = "agent: \(caller.claimedClient?.replacingOccurrences(of: " (claimed)", with: "") ?? "agent") \(stamp)"
        let live = (state == .running || state == .paused) && backend?.capabilities.contains(.liveSnapshot) == true
        var taken: SnapshotMeta?
        for kind in live ? [SnapshotMeta.Kind.live, .disk] : [.disk] where taken == nil {
            taken = try? await createSnapshot(name, kind: kind, origin: .agentSession)
        }
        guard let taken else {
            return RPCError(
                .invalidState, "auto-snapshot unavailable for this VM now: take a snapshot, or turn off auto-snapshot in its settings")
        }
        agentSessions[session] = AgentSession(snapshot: taken.id, connection: caller.connection)
        await pruneAgentSnapshots()
        return nil
    }

    /// Keeps the newest agent snapshots and every live session's first one.
    private func pruneAgentSnapshots() async {
        let store = SnapshotStore(lock: prepared.lock)
        let pinned = Set(agentSessions.values.filter { $0.connection != nil }.map(\.snapshot))
        guard let all = try? await Blocking.run({ try store.list() }) else { return }
        let agents = all.filter { $0.origin == .agentSession }.sorted { $0.createdAt > $1.createdAt }
        for old in agents.dropFirst(Self.keptAgentSnapshots) where !pinned.contains(old.id) {
            try? await Blocking.run { try store.delete(old.id) }
        }
        agentSessions = agentSessions.filter { $0.value.connection != nil }
    }
}

/// An agent session's snapshot, while its process (connection) lives.
struct AgentSession: Sendable {
    let snapshot: UUID
    weak var connection: ControlConnection?
}
