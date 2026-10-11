import Foundation
import VMPaneControl
import VMPaneCore

/// The helper's link to the guest agent: at most one live connection (a new one replaces the old, e.g. after
/// the agent restarted). After a protocol violation the hub refuses connections for a while, doubling from 1 s
/// to 60 s, so a misbehaving guest cannot keep the host busy.
public actor AgentHub {
    public struct Status: Equatable, Sendable {
        public var connected: Bool
        public var peer: AgentConnection.Peer?
    }

    public enum Event: Sendable {
        case connected(AgentConnection, AgentConnection.Peer)
        case disconnected
    }

    private let hostVersion: String
    private var current: AgentConnection?
    private var currentPeer: AgentConnection.Peer?
    private var refuseUntil: ContinuousClock.Instant?
    private var violationDelay: Duration = .seconds(1)
    private var waiters: [CheckedContinuation<AgentConnection?, Never>] = []
    /// Connection changes, for `agent.connectionChanged` and per-connection work (clock sync, notifications).
    public nonisolated let events: AsyncStream<Event>
    private let eventContinuation: AsyncStream<Event>.Continuation

    static let maxViolationDelay: Duration = .seconds(60)

    public init(hostVersion: String) {
        self.hostVersion = hostVersion
        (events, eventContinuation) = AsyncStream.makeStream(of: Event.self, bufferingPolicy: .bufferingNewest(16))
    }

    public var status: Status { Status(connected: current != nil, peer: currentPeer) }
    public var connection: AgentConnection? { current }

    /// Waits until the backoff after a violation is over.
    public func waitOutBackoff() async {
        guard let until = refuseUntil, until > .now else { return }
        try? await Task.sleep(until: until)
    }

    /// Runs a new connection on `fd` (owned) through `hello`, then makes it current until it closes.
    /// Returns when the connection has closed.
    public func serve(fd: Int32, helloTimeout: Duration?, token: String? = nil) async {
        if let until = refuseUntil, until > .now {
            close(fd)
            return
        }
        await serve(AgentConnection(fd: fd, hostVersion: hostVersion, token: token), helloTimeout: helloTimeout)
    }

    func serve(_ connection: AgentConnection, helloTimeout: Duration?) async {
        let peer: AgentConnection.Peer
        do {
            peer = try await connection.open(helloTimeout: helloTimeout)
        } catch {
            noteClose(error as? AgentConnection.ConnectionError)
            return
        }
        if let previous = current { await previous.close(.closed("replaced by a new agent connection")) }
        current = connection
        currentPeer = peer
        eventContinuation.yield(.connected(connection, peer))
        for waiter in waiters { waiter.resume(returning: connection) }
        waiters.removeAll()
        var reasons = connection.closed.makeAsyncIterator()
        let reason = await reasons.next()
        if current === connection {
            current = nil
            currentPeer = nil
            eventContinuation.yield(.disconnected)
        }
        noteClose(reason)
    }

    /// The current connection, waiting up to `timeout` for one.
    public func waitForConnection(timeout: Duration) async -> AgentConnection? {
        if let current { return current }
        let timer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            await self?.releaseWaiters()
        }
        defer { timer.cancel() }
        return await withCheckedContinuation { waiters.append($0) }
    }

    private func releaseWaiters() {
        for waiter in waiters { waiter.resume(returning: current) }
        waiters.removeAll()
    }

    /// Closes the current connection (the VM stopped).
    public func disconnect(_ reason: String) async {
        guard let connection = current else { return }
        await connection.close(.closed(reason))
    }

    private func noteClose(_ reason: AgentConnection.ConnectionError?) {
        if case .violation? = reason {
            refuseUntil = .now + violationDelay
            violationDelay = min(violationDelay * 2, Self.maxViolationDelay)
        } else if reason != nil {
            violationDelay = .seconds(1)
        }
    }
}
