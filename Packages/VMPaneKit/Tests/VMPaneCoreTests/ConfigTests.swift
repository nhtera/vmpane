import Foundation
import Testing

@testable import VMPaneCore

private func fixtureURL(_ name: String) throws -> URL {
    try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
}

/// Source location of a fixture, for regenerating it (`VMPANE_UPDATE_FIXTURES=1 swift test`).
private func sourceFixtureURL(_ name: String, file: String = #filePath) -> URL {
    URL(fileURLWithPath: file).deletingLastPathComponent().appendingPathComponent("Fixtures/\(name).json")
}

@Test func configFixtureIsCanonical() throws {
    let data = try Data(contentsOf: fixtureURL("config-v1"))
    let config = try CanonicalJSON.decoder().decode(VMConfigV1.self, from: data)
    let encoded = try CanonicalJSON.encode(config)
    if ProcessInfo.processInfo.environment["VMPANE_UPDATE_FIXTURES"] != nil {
        try encoded.write(to: sourceFixtureURL("config-v1"))
    }
    #expect(encoded == data, "fixture is not canonical; regenerate with VMPANE_UPDATE_FIXTURES=1")
}

@Test func configRoundTripIsByteStable() throws {
    let data = try Data(contentsOf: fixtureURL("config-v1"))
    let once = try CanonicalJSON.encode(CanonicalJSON.decoder().decode(VMConfigV1.self, from: data))
    let twice = try CanonicalJSON.encode(CanonicalJSON.decoder().decode(VMConfigV1.self, from: once))
    #expect(once == twice)
}

@Test func unknownKeysSurviveAtEveryLevel() throws {
    let data = try Data(contentsOf: fixtureURL("config-v1"))
    var config = try CanonicalJSON.decoder().decode(VMConfigV1.self, from: data)
    #expect(config.extras["futureTopLevel"]?["nested"] == [1, 2.5, "three", nil, true])
    #expect(config.extras["bigNumber"] == .int(9_007_199_254_740_993))
    #expect(config.cpu.extras["futureCPUKnob"] == "x")
    #expect(config.disks[0].extras["cache"] == ["mode": "writeback"])

    // A typed edit keeps the unknown keys around it.
    config.cpu.count = 8
    let reread = try CanonicalJSON.decoder().decode(VMConfigV1.self, from: CanonicalJSON.encode(config))
    #expect(reread.cpu.count == 8)
    #expect(reread.cpu.extras["futureCPUKnob"] == "x")
    #expect(reread.extras == config.extras)
}

@Test func typedFieldsDecode() throws {
    let config = try CanonicalJSON.decoder().decode(VMConfigV1.self, from: Data(contentsOf: fixtureURL("config-v1")))
    #expect(config.schemaVersion == 1)
    #expect(config.os == .linux)
    #expect(config.backend == .vz)
    #expect(config.network[0].macAddress == "52:54:00:12:34:56")
    #expect(config.portForwards[0].hostPort == 2222)
    #expect(config.vz?.rosetta == true)
    #expect(config.qemu == nil)
    #expect(config.mcp.policy == .off)
    #expect(config.mcp.tag == nil)
}

@Test(arguments: [GuestOS.macos, .linux, .windows])
func newConfigRoundTrips(os: GuestOS) throws {
    let config = VMConfigV1(VMConfigFields.new(name: "Test", os: os, macAddress: "52:54:00:00:00:01"))
    let decoded = try CanonicalJSON.decoder().decode(VMConfigV1.self, from: CanonicalJSON.encode(config))
    #expect(decoded == config)
    #expect(decoded.backend == (os == .windows ? .qemu : .vz))
    #expect((decoded.qemu != nil) == (os == .windows))
    // A Linux text console or installer cannot scale itself: one guest pixel per point, so its text is readable.
    #expect(decoded.display.scaling == (os == .linux ? .standard : .retina))
}

@Test func jsonValueKeepsIntegersExact() throws {
    let value: JSONValue = ["i": .int(Int64.max), "d": 0.5, "s": "x", "a": [true, nil]]
    let decoded = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
    #expect(decoded == value)
}

@Test func migratorAcceptsCurrentVersionUnchanged() throws {
    let document: [String: JSONValue] = ["schemaVersion": 1, "name": "x"]
    #expect(try ConfigMigrator.config.needsMigration(document) == false)
    #expect(try ConfigMigrator.config.migrate(document) == document)
}

@Test func migratorRejectsNewerAndMissingVersions() {
    #expect(throws: ConfigError.newerSchema(found: 2, supported: 1)) {
        try ConfigMigrator.config.migrate(["schemaVersion": 2])
    }
    #expect(throws: ConfigError.missingSchemaVersion) { try ConfigMigrator.config.migrate(["name": "x"]) }
}

@Test func migratorRunsStepsInOrder() throws {
    let migrator = ConfigMigrator(
        currentVersion: 3,
        steps: [
            1: { doc in doc["renamed"] = doc.removeValue(forKey: "old") },
            2: { doc in doc["added"] = .bool(true) },
        ])
    let result = try migrator.migrate(["schemaVersion": 1, "old": "v"])
    #expect(result == ["schemaVersion": 3, "renamed": "v", "added": true])
    #expect(throws: ConfigError.missingMigration(from: 1)) {
        try ConfigMigrator(currentVersion: 2, steps: [:]).migrate(["schemaVersion": 1])
    }
}
