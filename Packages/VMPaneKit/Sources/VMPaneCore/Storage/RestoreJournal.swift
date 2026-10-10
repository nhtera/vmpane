import Foundation

/// `restore.journal`: exists only while a snapshot restore swaps `current/`. Whoever next takes the
/// bundle lock replays it, so a crash at any point leaves either the old or the new set, never a mix.
public struct RestoreJournal: Codable, Equatable, Sendable {
    public static let schemaVersion = 1
    public var schemaVersion: Int
    public var snapshotId: UUID
    /// Name of the staging directory inside the bundle (`.restore-<generation>`).
    public var staging: String
    public var newGenerationId: UUID
}
