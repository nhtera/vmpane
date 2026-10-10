import Foundation

public enum ConfigError: Error, Equatable, Sendable {
    case notAnObject
    case missingSchemaVersion
    /// The file was written by a newer VMPane. Open read-only; never write it.
    case newerSchema(found: Int, supported: Int)
    case missingMigration(from: Int)
}

/// Migrates raw JSON documents (`config.json`, `meta.json`, …) step by step to the current schema.
/// Each step is a pure function from version N to N+1 and sets nothing else; the migrator bumps
/// `schemaVersion`. Run it only while holding `bundle.lock` (see `ConfigStore`).
public struct ConfigMigrator: Sendable {
    public typealias Step = @Sendable (inout [String: JSONValue]) throws -> Void

    public let currentVersion: Int
    private let steps: [Int: Step]

    /// `steps[n]` migrates version n to n + 1.
    public init(currentVersion: Int, steps: [Int: Step]) {
        self.currentVersion = currentVersion
        self.steps = steps
    }

    /// `config.json`. Version 1 is the first schema, so there are no steps yet.
    public static let config = ConfigMigrator(currentVersion: VMConfigFields.schemaVersion, steps: [:])

    public static func schemaVersion(of document: [String: JSONValue]) throws -> Int {
        guard let version = document["schemaVersion"]?.intValue else { throw ConfigError.missingSchemaVersion }
        return Int(version)
    }

    /// Whether `document` needs migrating; throws for newer or missing versions.
    public func needsMigration(_ document: [String: JSONValue]) throws -> Bool {
        let version = try Self.schemaVersion(of: document)
        if version > currentVersion { throw ConfigError.newerSchema(found: version, supported: currentVersion) }
        return version < currentVersion
    }

    public func migrate(_ document: [String: JSONValue]) throws -> [String: JSONValue] {
        var document = document
        var version = try Self.schemaVersion(of: document)
        if version > currentVersion { throw ConfigError.newerSchema(found: version, supported: currentVersion) }
        while version < currentVersion {
            guard let step = steps[version] else { throw ConfigError.missingMigration(from: version) }
            try step(&document)
            version += 1
            document["schemaVersion"] = .int(Int64(version))
        }
        return document
    }
}
