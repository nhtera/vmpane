import Foundation

/// `current/generation.json`: identifies the live file set. Every swap or disk-replacing operation mints a
/// new id; saved RAM state is only valid for the generation it was taken from.
public struct Generation: Codable, Equatable, Sendable {
    public static let schemaVersion = 1
    public var schemaVersion: Int
    public var generationId: UUID
    /// The snapshot this set was last restored from or snapshotted to: the parent of the next snapshot.
    public var parentSnapshotId: UUID?

    public init(generationId: UUID = UUID(), parentSnapshotId: UUID? = nil) {
        schemaVersion = Self.schemaVersion
        self.generationId = generationId
        self.parentSnapshotId = parentSnapshotId
    }

    public static func read(from url: URL) throws -> Generation {
        try CanonicalJSON.decoder().decode(Generation.self, from: Data(contentsOf: url))
    }

    public func write(to url: URL) throws {
        try DurableWrite.write(CanonicalJSON.encode(self), to: url)
    }
}
