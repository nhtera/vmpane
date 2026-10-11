import Foundation
import VMPaneCore

/// Finds and connects to the helper running a VM (app, CLI and MCP use this).
public enum HelperDiscovery {
    public struct Session: Sendable {
        public let client: UDSClient
        public let proto: Int
        public let helperVersion: String
        public let runtimeVersion: String
    }

    public enum DiscoveryError: Error, Equatable, Sendable {
        /// No live helper owns this VM.
        case notRunning
    }

    /// The control socket of the live helper for `vmID`, if any.
    public static func socket(for vmID: UUID, paths: VMPanePaths) -> URL? {
        let run = RunFiles(paths: paths, sid: ShortID(vmID))
        guard let helper = run.readHelper(), helper.vmId == vmID, helper.process.isAlive,
            FileManager.default.fileExists(atPath: run.socketURL.path)
        else { return nil }
        return run.socketURL
    }

    /// Connects and says `helper.hello`. Reconciles the run directory first, so a dead helper's files
    /// are not mistaken for a live one.
    public static func connect(
        to vmID: UUID, paths: VMPanePaths, clientName: String, clientVersion: String,
        kind: String, operatorClaim: Bool = false, sessionId: String? = nil
    ) async throws -> Session {
        await Blocking.run { _ = RunDirectoryReconciler.reconcile(paths: paths) }
        guard let socket = socket(for: vmID, paths: paths) else { throw DiscoveryError.notRunning }
        let client = try UDSClient.connect(to: socket)
        do {
            var params: [String: JSONValue] = [
                "proto": .int(Int64(ControlProtocol.version)), "minProto": .int(Int64(ControlProtocol.minimumVersion)),
                "client": [
                    "name": .string(clientName), "version": .string(clientVersion), "kind": .string(kind),
                    // Honoured only from the signed vmpane CLI, which checked it itself (InteractiveSession, OperatorGrant).
                    "operator": .bool(operatorClaim),
                ],
            ]
            // An agent session (one `vmpane mcp` process), for the audit log and its snapshot.
            if let sessionId { params["sessionId"] = .string(sessionId) }
            let hello = try await client.call(ControlMethod.helperHello.rawValue, params: .object(params))
            return Session(
                client: client, proto: Int(hello["proto"]?.intValue ?? 0),
                helperVersion: hello["helperVersion"]?.stringValue ?? "",
                runtimeVersion: hello["runtimeVersion"]?.stringValue ?? "")
        } catch {
            client.close()
            throw error
        }
    }
}
