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
        "helper.hello", "vm.info", "vm.screenshot", "vm.screen.read", "vm.snapshot.list", "vm.settings.get", "vm.ports.list",
        "agent.status",
        "vm.clipboard.read", "events.subscribe", "mcp.disableAll",
    ]

    static let keptAgentSnapshots = 5

    /// Takes the session's snapshot before its first change; a refusal when that is not possible.
    func snapshotBeforeAgentChange(_ request: RPCRequest, _ caller: CallerIdentity) async -> RPCError? {
        guard caller.identity != .ui, let session = caller.session, config.mcp.autoSnapshot,
            !Self.readOnlyMethods.contains(request.method), agentSessions[session] == nil
        else { return nil }
        // Concurrent first calls of a session wait for the one snapshot.
        if let pending = agentSnapshotTasks[session] {
            return await pending.value == nil ? Self.snapshotUnavailable : nil
        }
        let task = Task { await self.takeAgentSnapshot(caller) }
        agentSnapshotTasks[session] = task
        let taken = await task.value
        agentSnapshotTasks[session] = nil
        guard let taken else { return Self.snapshotUnavailable }
        agentSessions[session] = AgentSession(snapshot: taken.id, connection: caller.connection)
        await pruneAgentSnapshots()
        return nil
    }

    static let snapshotUnavailable = RPCError(
        .invalidState, "auto-snapshot unavailable for this VM now: take a snapshot, or turn off auto-snapshot in its settings")

    private func takeAgentSnapshot(_ caller: CallerIdentity) async -> SnapshotMeta? {
        let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
        let name = "agent: \(caller.claimedClient?.replacingOccurrences(of: " (claimed)", with: "") ?? "agent") \(stamp)"
        let live = (state == .running || state == .paused) && backend?.capabilities.contains(.liveSnapshot) == true
        var taken: SnapshotMeta?
        for kind in live ? [SnapshotMeta.Kind.live, .disk] : [.disk] where taken == nil {
            taken = try? await createSnapshot(name, kind: kind, origin: .agentSession)
        }
        // A live snapshot pauses the guest while its memory is saved: input sent the moment it runs again can be lost
        // (Windows 11 build 26300 dropped an agent's first Windows key so, #11). The guest takes input again first.
        if taken?.kind == .live { await waitUntilGuestTakesInput() }
        return taken
    }

    /// The least a guest gets to catch up after the live undo snapshot before the agent's call goes on.
    static let afterLiveSnapshot: Duration = .seconds(1)
    /// The key that asks the guest whether it takes input: right Ctrl alone, which nothing acts on and terminals never
    /// see (a function key reaches them as an escape sequence).
    static let probeUsage: UInt16 = 0xE4
    /// How long a probe has to arrive before it is sent again, and how long the helper tries in all: after the first
    /// live snapshot of a run, Windows 11 (build 26300) took no input for 3.5 s once and over 5 s another time, and at
    /// once (about 0.1 s) after later ones.
    static let probeWait: Duration = .milliseconds(700)
    static let inputReadyTimeout: Duration = .seconds(10)

    /// Returns once the guest takes input again, and not before `afterLiveSnapshot`: a probe key is sent, again if
    /// need be, until the guest's agent says its session had input since (`input.idle`). An agent that cannot say,
    /// no signed-in session, a paused VM, or agents stopped meanwhile: the fixed wait alone.
    func waitUntilGuestTakesInput() async {
        let started = ContinuousClock.now
        if let probes = await probeUntilGuestTakesInput() {
            let waited = ContinuousClock.now - started
            Self.log.notice("the guest took input again after \(waited, privacy: .public) (\(probes, privacy: .public) probes)")
        }
        let left = started + Self.afterLiveSnapshot - ContinuousClock.now
        if left > .zero { try? await Task.sleep(for: left) }
    }

    /// Probes until the guest reports input since a probe (the probes it took), or gives up: no way to tell, the
    /// deadline, or agents stopped or taken over (nil).
    private func probeUntilGuestTakesInput() async -> Int? {
        let hub = agentHub
        guard state == .running, let backend, let connection = await hub.connection,
            await hub.status.peer?.hello.caps?.contains(AgentCap.inputIdle) == true,
            await Self.guestIdleMs(connection) != nil
        else { return nil }
        let deadline = ContinuousClock.now + Self.inputReadyTimeout
        var probes = 0
        var lastIdle: UInt64 = 0
        while ContinuousClock.now < deadline, !killSwitchEngaged, !activity.takenOver, state == .running {
            let sent = ContinuousClock.now
            probes += 1
            try? await backend.send(.key(usage: Self.probeUsage, down: true))
            // The key must not stay down: a failed release is tried once more.
            if (try? await backend.send(.key(usage: Self.probeUsage, down: false))) == nil {
                try? await backend.send(.key(usage: Self.probeUsage, down: false))
            }
            while ContinuousClock.now - sent < Self.probeWait {
                guard let idle = await Self.guestIdleMs(connection) else { return nil }
                lastIdle = idle
                // Input since the probe went (the guest's tick counts in steps of about 16 ms).
                if Double(idle) <= (ContinuousClock.now - sent) / .milliseconds(1) + 20 { return probes }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        Self.log.notice(
            """
            the guest did not report input within \(Self.inputReadyTimeout, privacy: .public) of the live snapshot \
            (\(probes, privacy: .public) probes, last idle \(lastIdle, privacy: .public) ms)
            """)
        return nil
    }

    /// The guest session's milliseconds since its last input, nil when its agent cannot say.
    static func guestIdleMs(_ connection: AgentConnection) async -> UInt64? {
        guard let reply = try? await connection.call(AgentMethod.inputIdle, timeout: .seconds(2)) else { return nil }
        return reply.result["idleMs"]?.intValue.flatMap { UInt64(exactly: $0) }
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
