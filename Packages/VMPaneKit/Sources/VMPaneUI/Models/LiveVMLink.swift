import Foundation
import VMPaneControl
import VMPaneCore

/// What a VM's helper tells the library: its state, and what AI agents are doing on it (`vm.agent.activity`).
public enum LiveVMEvent: Sendable {
    case state(VMRunState)
    case activity(JSONValue)
}

/// How the library reaches running VMs: each one's helper, over its control socket.
public protocol LiveVMLink: Sendable {
    /// The VM's state (and agents' activity) now and as it changes, until its helper goes away; nil when no helper runs it.
    func watch(_ vmID: UUID) async -> AsyncStream<LiveVMEvent>?
    /// A control request to the VM's helper.
    func call(_ vmID: UUID, _ method: String, params: JSONValue?) async throws -> JSONValue
}

/// `LiveVMLink` over `HelperDiscovery`.
public struct HelperLinks: LiveVMLink {
    let paths: VMPanePaths

    public init(paths: VMPanePaths) {
        self.paths = paths
    }

    private func connect(_ vmID: UUID) async throws -> HelperDiscovery.Session {
        try await HelperDiscovery.connect(to: vmID, paths: paths, clientName: "VMPane", clientVersion: VMPane.version, kind: "ui")
    }

    public func watch(_ vmID: UUID) async -> AsyncStream<LiveVMEvent>? {
        guard let session = try? await connect(vmID) else { return nil }
        let client = session.client
        guard let info = try? await client.call(ControlMethod.vmInfo.rawValue),
            let first = info["state"]?.stringValue.flatMap(VMRunState.init(rawValue:)),
            (try? await client.call(ControlMethod.eventsSubscribe.rawValue, params: ["topics": ["vm"]])) != nil
        else {
            client.close()
            return nil
        }
        // An older helper has no activity to tell.
        let activity = try? await client.call(ControlMethod.vmAgentActivity.rawValue)
        return AsyncStream { continuation in
            continuation.yield(.state(first))
            if let activity { continuation.yield(.activity(activity)) }
            let task = Task {
                for await note in client.notifications {
                    switch note.method {
                    case ControlNotification.vmStateChanged.rawValue:
                        if let state = note.params?["state"]?.stringValue.flatMap(VMRunState.init(rawValue:)) {
                            continuation.yield(.state(state))
                        }
                    case ControlNotification.agentActivity.rawValue:
                        if let params = note.params { continuation.yield(.activity(params)) }
                    default:
                        break
                    }
                }
                continuation.finish()  // the helper went away
            }
            continuation.onTermination = { _ in
                task.cancel()
                client.close()
            }
        }
    }

    public func call(_ vmID: UUID, _ method: String, params: JSONValue?) async throws -> JSONValue {
        let session = try await connect(vmID)
        defer { session.client.close() }
        return try await session.client.call(method, params: params)
    }
}
