import Foundation

/// Reading and writing `config.json`. Writes and persisted migrations need the bundle lock; without it
/// an older config is migrated in memory only and saved later by the lock holder.
public enum ConfigStore {
    public static func readDocument(_ bundle: VMBundle) throws -> [String: JSONValue] {
        let value = try CanonicalJSON.decoder().decode(JSONValue.self, from: Data(contentsOf: bundle.configURL))
        guard let object = value.objectValue else { throw ConfigError.notAnObject }
        return object
    }

    /// Loads the config for reading. Throws `ConfigError.newerSchema` for configs from a newer VMPane.
    public static func load(_ bundle: VMBundle, migrator: ConfigMigrator = .config) throws -> VMConfigV1 {
        try decode(migrator.migrate(readDocument(bundle)))
    }

    /// Loads the config and, if it is older than this build, migrates it on disk: a backup
    /// `config.v<N>.<timestamp>.bak.json` first, then a durable write.
    public static func loadAndMigrate(
        _ lock: BundleLock, migrator: ConfigMigrator = .config,
        now: Date = Date()
    ) throws -> VMConfigV1 {
        let bundle = lock.bundle
        let document = try readDocument(bundle)
        guard try migrator.needsMigration(document) else { return try decode(document) }
        let version = try ConfigMigrator.schemaVersion(of: document)
        let stamp = Int(now.timeIntervalSince1970)
        let backup = bundle.url.appendingPathComponent("config.v\(version).\(stamp).bak.json")
        try DurableWrite.write(Data(contentsOf: bundle.configURL), to: backup)
        let migrated = try migrator.migrate(document)
        try DurableWrite.write(CanonicalJSON.encode(JSONValue.object(migrated)), to: bundle.configURL)
        return try decode(migrated)
    }

    public static func save(_ config: VMConfigV1, holding lock: BundleLock) throws {
        try DurableWrite.write(CanonicalJSON.encode(config), to: lock.bundle.configURL)
    }

    private static func decode(_ document: [String: JSONValue]) throws -> VMConfigV1 {
        let data = try CanonicalJSON.encoder().encode(JSONValue.object(document))
        let config = try CanonicalJSON.decoder().decode(VMConfigV1.self, from: data)
        try validate(config)
        return config
    }

    /// Checks that cannot be expressed in the types: disk files stay inside the bundle.
    public static func validate(_ config: VMConfigV1) throws {
        let probe = VMBundle(uncheckedURL: URL(fileURLWithPath: "/probe.vmpane"))
        for disk in config.disks { _ = try probe.fileURL(relativePath: disk.file) }
    }
}
