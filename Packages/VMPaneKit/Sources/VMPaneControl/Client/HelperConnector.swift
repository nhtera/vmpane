import Foundation
import VMPaneCore

/// Connects a client (CLI, MCP) to a VM's helper, launching the helper first (headless) when the command needs
/// a running VM process and none is there.
public struct HelperConnector: Sendable {
    public let paths: VMPanePaths
    public let clientName: String
    public let clientVersion: String
    /// "cli", "mcp": what the client says it is (recorded; identity comes from its code signature).
    public let kind: String
    /// This process passed the operator checks (sent in `helper.hello`; the helper honours it only from the CLI).
    public let operatorClaim: Bool
    /// The agent session this client is (`vmpane mcp`), if any.
    public let sessionId: String?
    /// Starts the helper for a bundle (`LaunchCoordinator.launch` from the app the client lives in).
    public let launch: @Sendable (VMBundle) throws -> Void
    /// The runtime `launch` starts helpers from now (`RuntimeStore.version`; an update changes it under a running
    /// `vmpane mcp`); nil: a live helper is always used.
    public let currentRuntime: @Sendable () -> String?

    public init(
        paths: VMPanePaths, clientName: String, clientVersion: String, kind: String, operatorClaim: Bool = false,
        sessionId: String? = nil, currentRuntime: @escaping @Sendable () -> String? = { nil },
        launch: @escaping @Sendable (VMBundle) throws -> Void
    ) {
        self.currentRuntime = currentRuntime
        self.sessionId = sessionId
        self.operatorClaim = operatorClaim
        self.paths = paths
        self.clientName = clientName
        self.clientVersion = clientVersion
        self.kind = kind
        self.launch = launch
    }

    /// The same connector for a client of another name (an MCP client's own, once it said it).
    public func named(_ name: String) -> HelperConnector {
        HelperConnector(
            paths: paths, clientName: name, clientVersion: clientVersion, kind: kind, operatorClaim: operatorClaim,
            sessionId: sessionId, currentRuntime: currentRuntime, launch: launch)
    }

    /// A session with the VM's running helper; `notRunning` when there is none.
    public func connect(_ vmID: UUID) async throws -> HelperDiscovery.Session {
        try await HelperDiscovery.connect(
            to: vmID, paths: paths, clientName: clientName, clientVersion: clientVersion, kind: kind, operatorClaim: operatorClaim,
            sessionId: sessionId)
    }

    /// A session with the VM's helper, launching it when needed (up to `timeout` for it to answer). A helper from
    /// another runtime (before an update) whose VM is stopped quits first, so the VM gets this one's (#12).
    public func connectLaunching(_ item: VMLibrary.Item, timeout: Duration = .seconds(20)) async throws -> HelperDiscovery.Session {
        if let session = try? await connect(item.id) {
            guard try await retired(session, item) else { return session }
        }
        let bundle = item.bundle
        try await Blocking.run { try launch(bundle) }
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let session = try? await connect(item.id) { return session }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw RPCError(.backendUnavailable, "the VM's helper did not start within \(timeout)")
    }

    /// Whether `session`'s helper is from another runtime than `launch`'s (before an update).
    public func isOutdated(_ session: HelperDiscovery.Session) -> Bool {
        RuntimeStore.isOutdated(session.runtimeVersion, current: currentRuntime())
    }

    /// Whether `session`'s helper was outdated with its VM stopped (not suspended), and has quit; false keeps it. It
    /// is told by SIGTERM, which it takes as the Mac's logout: no agent level or approval needed to let a helper go
    /// whose VM is not running (this one's was a moment ago), and nothing of the VM's is lost.
    private func retired(_ session: HelperDiscovery.Session, _ item: VMLibrary.Item) async throws -> Bool {
        guard isOutdated(session), let info = try? await session.client.call(ControlMethod.vmInfo.rawValue),
            [VMRunState.stopped.rawValue, VMRunState.error.rawValue].contains(info["state"]?.stringValue ?? ""),
            info["suspended"] != true,
            let helper = RunFiles(paths: paths, sid: ShortID(item.id)).readHelper()?.process, helper.isAlive
        else { return false }
        session.client.close()
        kill(helper.pid, SIGTERM)
        let deadline = ContinuousClock.now + .seconds(15)
        while await Blocking.run({ helper.isAlive }) {
            guard ContinuousClock.now < deadline else {
                let name = item.config?.name ?? "the VM"
                throw RPCError(.busy, "the helper of \(name) from the previous version of VMPane did not quit: try again in a moment")
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        return true
    }
}
