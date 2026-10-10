import Foundation
import Testing

@testable import VMPaneCore

func makeConfig(name: String = "Test", os: GuestOS = .linux, mac: String? = nil) -> VMConfigV1 {
    VMConfigV1(VMConfigFields.new(name: name, os: os, macAddress: mac ?? MachineIdentity.randomMACAddress()))
}

private func mode(_ url: URL) throws -> Int {
    try #require(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
}

@Test func createLaysOutOwnerOnlyBundle() throws {
    try withTempDirectory { dir in
        let bundle = try VMBundle.create(at: dir.appendingPathComponent("A.vmpane"), config: makeConfig())
        for directory in [
            bundle.url, bundle.currentDirectory, bundle.auxDirectory, bundle.stateDirectory,
            bundle.snapshotsDirectory, bundle.logsDirectory,
        ] {
            #expect(try mode(directory) == 0o700, "\(directory.lastPathComponent)")
        }
        #expect(try mode(bundle.configURL) == 0o600)
        #expect(try mode(bundle.generationURL) == 0o600)
        #expect(throws: BundleError.alreadyExists) { try VMBundle.create(at: bundle.url, config: makeConfig()) }
    }
}

@Test func openRejectsSymlinksAndNonBundles() throws {
    try withTempDirectory { dir in
        let bundle = try VMBundle.create(at: dir.appendingPathComponent("A.vmpane"), config: makeConfig())
        let link = dir.appendingPathComponent("L.vmpane")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: bundle.url)
        #expect(throws: BundleError.symlink) { try VMBundle.open(link) }
        let empty = dir.appendingPathComponent("E.vmpane")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: false)
        #expect(throws: BundleError.notABundle) { try VMBundle.open(empty) }
        #expect(throws: BundleError.notABundle) { try VMBundle.open(dir.appendingPathComponent("missing.vmpane")) }
        #expect(try VMBundle.open(bundle.url) == bundle)
    }
}

@Test func bundleLockIsExclusiveUntilReleased() throws {
    try withTempDirectory { dir in
        let bundle = try VMBundle.create(at: dir.appendingPathComponent("A.vmpane"), config: makeConfig())
        let first = try #require(try bundle.tryLock(retryingFor: 5))
        #expect(try bundle.tryLock() == nil)
        first.release()
        let second = try #require(try bundle.tryLock(retryingFor: 1))  // other tests launch processes meanwhile
        try bundle.delete(holding: second)
        #expect(!FileManager.default.fileExists(atPath: bundle.url.path))
    }
}

@Test func configSaveAndLoadRoundTrip() throws {
    try withTempDirectory { dir in
        let bundle = try VMBundle.create(at: dir.appendingPathComponent("A.vmpane"), config: makeConfig(name: "One"))
        let lock = try #require(try bundle.tryLock(retryingFor: 5))
        var config = try ConfigStore.load(bundle)
        config.name = "Two"
        config.extras["later"] = "kept"
        try ConfigStore.save(config, holding: lock)
        #expect(try ConfigStore.load(bundle) == config)
    }
}

private let toV2 = ConfigMigrator(currentVersion: 2, steps: [1: { doc in doc["addedInV2"] = .bool(true) }])

@Test func migrationIsPersistedWithBackupUnderLock() throws {
    try withTempDirectory { dir in
        let bundle = try VMBundle.create(at: dir.appendingPathComponent("A.vmpane"), config: makeConfig())
        let original = try Data(contentsOf: bundle.configURL)
        let lock = try #require(try bundle.tryLock(retryingFor: 5))
        let config = try ConfigStore.loadAndMigrate(lock, migrator: toV2, now: Date(timeIntervalSince1970: 1_000))
        #expect(config.schemaVersion == 2)
        #expect(config.extras["addedInV2"] == true)
        #expect(try ConfigStore.readDocument(bundle)["schemaVersion"] == 2)
        let backup = bundle.url.appendingPathComponent("config.v1.1000.bak.json")
        #expect(try Data(contentsOf: backup) == original)
    }
}

@Test func migrationWithoutTheLockStaysInMemory() throws {
    try withTempDirectory { dir in
        let bundle = try VMBundle.create(at: dir.appendingPathComponent("A.vmpane"), config: makeConfig())
        let helperLock = try #require(try bundle.tryLock(retryingFor: 5))
        defer { helperLock.release() }
        let original = try Data(contentsOf: bundle.configURL)
        #expect(try bundle.tryLock() == nil)  // a helper holds it: the migration is deferred
        let config = try ConfigStore.load(bundle, migrator: toV2)
        #expect(config.schemaVersion == 2)
        #expect(try Data(contentsOf: bundle.configURL) == original)
    }
}

@Test func newerConfigIsRefused() throws {
    try withTempDirectory { dir in
        let bundle = try VMBundle.create(at: dir.appendingPathComponent("A.vmpane"), config: makeConfig())
        var document = try ConfigStore.readDocument(bundle)
        document["schemaVersion"] = 99
        try DurableWrite.write(CanonicalJSON.encode(JSONValue.object(document)), to: bundle.configURL)
        #expect(throws: ConfigError.newerSchema(found: 99, supported: 1)) { try ConfigStore.load(bundle) }
    }
}

@Test func randomMACsAreLocallyAdministeredUnicast() {
    for _ in 0..<200 {
        let mac = MachineIdentity.randomMACAddress()
        let first = UInt8(mac.prefix(2), radix: 16) ?? 0
        #expect(first & 0x02 == 0x02)
        #expect(first & 0x01 == 0)
        #expect(mac.count == 17)
    }
}

@Test func stagedCreationNeverLeavesAHalfMadeBundle() throws {
    try withTempDirectory { dir in
        struct Boom: Error {}
        let target = dir.appendingPathComponent("New.vmpane")
        #expect(throws: Boom.self) {
            try VMBundle.createStaged(at: target, config: makeConfig()) { _ in throw Boom() }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
        let made = try VMBundle.createStaged(at: target, config: makeConfig()) { staged in
            try Data("disk".utf8).write(to: staged.fileURL(relativePath: "current/disk.img"))
        }
        #expect(try VMBundle.open(made.url) == made)
        #expect(throws: BundleError.alreadyExists) { try VMBundle.createStaged(at: target, config: makeConfig()) { _ in } }
        #expect(throws: BundleError.alreadyExists) { try VMBundle.create(at: target, config: makeConfig()) }
    }
}

@Test(arguments: ["../outside.img", "/etc/passwd", "current/../../x", "", "current//disk.img", "./disk.img"])
func diskPathsMustStayInsideTheBundle(path: String) throws {
    try withTempDirectory { dir in
        var config = makeConfig()
        config.disks[0].file = path
        let bundle = try VMBundle.create(at: dir.appendingPathComponent("P.vmpane"), config: config)
        #expect(throws: BundleError.unsafePath(path)) { try ConfigStore.load(bundle) }
    }
}

@Test func symlinkedPartsAreRefused() throws {
    try withTempDirectory { dir in
        let bundle = try VMBundle.create(at: dir.appendingPathComponent("L.vmpane"), config: makeConfig())
        let elsewhere = dir.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.removeItem(at: bundle.snapshotsDirectory)
        try FileManager.default.createSymbolicLink(at: bundle.snapshotsDirectory, withDestinationURL: elsewhere)
        #expect(throws: BundleError.symlink) { try VMBundle.open(bundle.url) }
    }
}

@Test func deleteIsCrashSafe() throws {
    try withTempDirectory { dir in
        let bundle = try VMBundle.create(at: dir.appendingPathComponent("D.vmpane"), config: makeConfig())
        try bundle.delete(holding: try #require(try bundle.tryLock(retryingFor: 5)))
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
    }
}
