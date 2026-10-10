import Foundation

/// `snapshots/<id>/meta.json`, written last: a snapshot exists exactly when its meta.json does.
public struct SnapshotMeta: Codable, Equatable, Sendable {
    public static let schemaVersion = 1

    public enum Kind: String, Codable, Sendable {
        /// Disks + RAM state: restores into the running state.
        case live
        /// Disks only: restores to a cold boot.
        case disk
    }

    public enum Origin: String, Codable, Sendable {
        case user
        /// Taken automatically before an agent session (MCP).
        case agentSession
    }

    public var schemaVersion: Int
    public var id: UUID
    public var name: String
    public var createdAt: Date
    public var parentId: UUID?
    public var kind: Kind
    /// Generation of the live set the snapshot was taken from.
    public var generationId: UUID
    public var deviceSetHash: String
    public var hostBuild: String
    public var backendVersion: String
    public var origin: Origin
    public var sizeBytes: UInt64
}

/// `state/suspend.json` beside saved RAM state: which live set the state belongs to.
public struct StateMeta: Codable, Equatable, Sendable {
    public static let fileName = "suspend.json"
    public var generationId: UUID
    public var deviceSetHash: String
    public var hostBuild: String
    public var backendVersion: String

    public init(generationId: UUID, deviceSetHash: String, hostBuild: String, backendVersion: String) {
        self.generationId = generationId
        self.deviceSetHash = deviceSetHash
        self.hostBuild = hostBuild
        self.backendVersion = backendVersion
    }
}

/// What to do with saved RAM state at start.
public enum SavedStateDecision: Equatable, Sendable {
    case none
    /// Generation and device set match: resume from it.
    case resume
    /// Mismatch (or unreadable): cold boot and delete the state. One rule, no retry.
    case discard
}

public enum SavedStateRule {
    /// The generation rule: saved state is valid only for the live set and device set it was taken from.
    public static func decide(stateMeta: StateMeta?, stateExists: Bool, current: Generation, deviceSetHash: String) -> SavedStateDecision {
        guard stateExists else { return .none }
        guard let meta = stateMeta, meta.generationId == current.generationId, meta.deviceSetHash == deviceSetHash else {
            return .discard
        }
        return .resume
    }
}
