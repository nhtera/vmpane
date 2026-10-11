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
    /// Starts the helper for a bundle (`LaunchCoordinator.launch` from the app the client lives in).
    public let launch: @Sendable (VMBundle) throws -> Void

    public init(
        paths: VMPanePaths, clientName: String, clientVersion: String, kind: String, launch: @escaping @Sendable (VMBundle) throws -> Void
    ) {
        self.paths = paths
        self.clientName = clientName
        self.clientVersion = clientVersion
        self.kind = kind
        self.launch = launch
    }

    /// A session with the VM's running helper; `notRunning` when there is none.
    public func connect(_ vmID: UUID) async throws -> HelperDiscovery.Session {
        try await HelperDiscovery.connect(to: vmID, paths: paths, clientName: clientName, clientVersion: clientVersion, kind: kind)
    }

    /// A session with the VM's helper, launching it when needed (up to `timeout` for it to answer).
    public func connectLaunching(_ item: VMLibrary.Item, timeout: Duration = .seconds(20)) async throws -> HelperDiscovery.Session {
        if let session = try? await connect(item.id) { return session }
        let bundle = item.bundle
        try await Blocking.run { try launch(bundle) }
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let session = try? await connect(item.id) { return session }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw RPCError(.backendUnavailable, "the VM's helper did not start within \(timeout)")
    }
}
