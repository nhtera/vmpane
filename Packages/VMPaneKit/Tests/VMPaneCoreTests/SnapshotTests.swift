import Foundation
import Testing

@testable import VMPaneCore

private struct SimulatedCrash: Error {}
private let context = SnapshotContext(deviceSetHash: "hash", hostBuild: "24G419", backendVersion: "test")

/// A bundle whose live set is marked with `marker` in both the disk and an aux file.
private func makeBundle(_ dir: URL, marker: String = "OLD") throws -> (VMBundle, BundleLock) {
    let bundle = try VMBundle.create(at: dir.appendingPathComponent("A.vmpane"), config: makeConfig())
    try setMarker(bundle, marker)
    return (bundle, try #require(try bundle.tryLock()))
}

private func setMarker(_ bundle: VMBundle, _ marker: String) throws {
    try Data(marker.utf8).write(to: bundle.currentDirectory.appendingPathComponent("disk.img"))
    try Data(marker.utf8).write(to: bundle.auxDirectory.appendingPathComponent("efi_vars.fd"))
}

/// The marker of the live set; fails the test if disk and aux disagree (a mixed set).
private func liveMarker(_ bundle: VMBundle) throws -> String {
    let disk = try String(contentsOf: bundle.currentDirectory.appendingPathComponent("disk.img"), encoding: .utf8)
    let aux = try String(contentsOf: bundle.auxDirectory.appendingPathComponent("efi_vars.fd"), encoding: .utf8)
    #expect(disk == aux, "mixed live set: disk \(disk), aux \(aux)")
    return disk
}

private func leftovers(_ bundle: VMBundle) throws -> [String] {
    let fm = FileManager.default
    let top = try fm.contentsOfDirectory(atPath: bundle.url.path).filter { $0.hasPrefix(".") || $0 == "restore.journal" }
    let snaps = try fm.contentsOfDirectory(atPath: bundle.snapshotsDirectory.path).filter { UUID(uuidString: $0) == nil }
    return top + snaps
}

@Test func snapshotCreateListDeleteAndParents() throws {
    try withTempDirectory { dir in
        let (_, lock) = try makeBundle(dir)
        let store = SnapshotStore(lock: lock)
        let first = try store.create(name: "one", kind: .disk, origin: .user, context: context)
        let second = try store.create(
            name: "two", kind: .disk, origin: .agentSession, context: context,
            now: first.createdAt.addingTimeInterval(1))
        #expect(first.parentId == nil)
        #expect(second.parentId == first.id)
        #expect(try store.list().map(\.name) == ["one", "two"])
        try store.delete(first.id)
        #expect(try store.list().map(\.id) == [second.id])
        #expect(throws: SnapshotError.notFound(first.id)) { try store.delete(first.id) }
        #expect(throws: SnapshotError.missingState) {
            try store.create(name: "live", kind: .live, origin: .user, context: context)
        }
    }
}

@Test(arguments: [SnapshotStep.createdPartial, .cloned, .wroteMeta, .committed])
func snapshotCreateCrashLeavesAllOrNothing(at crashStep: SnapshotStep) throws {
    try withTempDirectory { dir in
        let (bundle, lock) = try makeBundle(dir)
        var store = SnapshotStore(lock: lock)
        store.faultInjector = { step in if step == crashStep { throw SimulatedCrash() } }
        #expect(throws: SimulatedCrash.self) { try store.create(name: "s", kind: .disk, origin: .user, context: context) }

        let recovered = SnapshotStore(lock: lock)
        try recovered.recover()
        let snapshots = try recovered.list()
        #expect(snapshots.count == (crashStep == .committed ? 1 : 0))
        #expect(try leftovers(bundle).isEmpty)
        #expect(try liveMarker(bundle) == "OLD")
    }
}

@Test(arguments: [SnapshotStep.builtStaging, .wroteJournal, .swapped, .removedOldSet])
func snapshotRestoreCrashLeavesOldOrNewSet(at crashStep: SnapshotStep) throws {
    try withTempDirectory { dir in
        let (bundle, lock) = try makeBundle(dir, marker: "SNAP")
        let snapshot = try SnapshotStore(lock: lock).create(name: "s", kind: .disk, origin: .user, context: context)
        try setMarker(bundle, "OLD")
        let before = try Generation.read(from: bundle.generationURL)

        var store = SnapshotStore(lock: lock)
        store.faultInjector = { step in if step == crashStep { throw SimulatedCrash() } }
        #expect(throws: SimulatedCrash.self) { try store.restore(snapshot.id) }

        try SnapshotStore(lock: lock).recover()
        let marker = try liveMarker(bundle)
        let generation = try Generation.read(from: bundle.generationURL)
        if [.swapped, .removedOldSet].contains(crashStep) {
            #expect(marker == "SNAP")
            #expect(generation.generationId != before.generationId)
            #expect(generation.parentSnapshotId == snapshot.id)
        } else {
            #expect(marker == "OLD")
            #expect(generation == before)
        }
        #expect(try leftovers(bundle).isEmpty)
        #expect(try SnapshotStore(lock: lock).list().count == 1)  // the snapshot itself is untouched
    }
}

@Test func liveRestoreRetagsStateWithTheNewGeneration() throws {
    try withTempDirectory { dir in
        let (bundle, lock) = try makeBundle(dir)
        let generation = try Generation.read(from: bundle.generationURL)
        let saved = dir.appendingPathComponent("saved", isDirectory: true)
        try FileManager.default.createDirectory(at: saved, withIntermediateDirectories: true)
        try Data("ram".utf8).write(to: saved.appendingPathComponent("suspend.qemustate"))
        try DurableWrite.write(
            CanonicalJSON.encode(
                StateMeta(
                    generationId: generation.generationId, deviceSetHash: "hash",
                    hostBuild: "b", backendVersion: "v")),
            to: saved.appendingPathComponent(StateMeta.fileName))
        let store = SnapshotStore(lock: lock)
        let snapshot = try store.create(
            name: "live", kind: .live, origin: .user, context: context,
            stateFiles: [
                saved.appendingPathComponent("suspend.qemustate"), saved.appendingPathComponent(StateMeta.fileName),
            ])
        let restored = try store.restore(snapshot.id)
        let stateMetaURL = bundle.stateDirectory.appendingPathComponent(StateMeta.fileName)
        let meta = try CanonicalJSON.decoder().decode(StateMeta.self, from: Data(contentsOf: stateMetaURL))
        #expect(meta.generationId == restored.generationId)
        #expect(SavedStateRule.decide(stateMeta: meta, stateExists: true, current: restored, deviceSetHash: "hash") == .resume)
    }
}

@Test func savedStateRule() {
    let generation = Generation()
    let meta = StateMeta(generationId: generation.generationId, deviceSetHash: "h", hostBuild: "b", backendVersion: "v")
    #expect(SavedStateRule.decide(stateMeta: nil, stateExists: false, current: generation, deviceSetHash: "h") == .none)
    #expect(SavedStateRule.decide(stateMeta: meta, stateExists: true, current: generation, deviceSetHash: "h") == .resume)
    #expect(SavedStateRule.decide(stateMeta: meta, stateExists: true, current: Generation(), deviceSetHash: "h") == .discard)
    #expect(SavedStateRule.decide(stateMeta: meta, stateExists: true, current: generation, deviceSetHash: "other") == .discard)
    #expect(SavedStateRule.decide(stateMeta: nil, stateExists: true, current: generation, deviceSetHash: "h") == .discard)
}

@Test func deviceSetHashIgnoresNonDeviceSettings() {
    let config = makeConfig(mac: "52:54:00:00:00:01")
    let base = DeviceSet(config).hash
    var renamed = config
    renamed.name = "Other"
    renamed.mcp.policy = .admin
    renamed.ui.closeAction = .stop
    renamed.extras["future"] = true
    renamed.portForwards = []
    #expect(DeviceSet(renamed).hash == base)
    var changed = config
    changed.network[0].macAddress = "52:54:00:00:00:02"
    #expect(DeviceSet(changed).hash != base)
    var bigger = config
    bigger.cpu.count += 1
    #expect(DeviceSet(bigger).hash != base)
}

@Test func spaceGuardNeedsRAMPlusMargin() throws {
    let gib: UInt64 = 1 << 30
    #expect(SpaceGuard.requiredBytes(memoryBytes: 10 * gib) == 11 * gib + 5 * gib)
    let here = URL(fileURLWithPath: "/")
    #expect(throws: InsufficientSpace(requiredBytes: SpaceGuard.requiredBytes(memoryBytes: 8 * gib), availableBytes: 8 * gib)) {
        try SpaceGuard.check(memoryBytes: 8 * gib, at: here, available: { _ in 8 * gib })
    }
    try SpaceGuard.check(memoryBytes: 8 * gib, at: here, available: { _ in 20 * gib })
}

@Test func spaceGuardRefusesOnANearlyFullVolume() throws {
    try withTempDirectory { dir in
        let image = dir.appendingPathComponent("small.dmg")
        let mount = dir.appendingPathComponent("mnt", isDirectory: true)
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        try shell("/usr/bin/hdiutil", ["create", "-quiet", "-size", "20m", "-fs", "APFS", "-volname", "VPSMALL", image.path])
        try shell("/usr/bin/hdiutil", ["attach", "-quiet", "-nobrowse", "-mountpoint", mount.path, image.path])
        defer { try? shell("/usr/bin/hdiutil", ["detach", "-quiet", "-force", mount.path]) }
        #expect(throws: InsufficientSpace.self) { try SpaceGuard.check(memoryBytes: 1 << 30, at: mount) }
    }
}

func shell(_ tool: String, _ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = arguments
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw POSIXError(.EIO) }
}

@Test func fullCloneIsANewMachineWithoutState() throws {
    try withTempDirectory { dir in
        let source = try VMBundle.create(at: dir.appendingPathComponent("W.vmpane"), config: makeConfig(os: .windows))
        try Data("disk".utf8).write(to: source.currentDirectory.appendingPathComponent("disk.img"))
        try Data("ram".utf8).write(to: source.stateDirectory.appendingPathComponent("suspend.qemustate"))
        try Data("id".utf8).write(to: source.auxDirectory.appendingPathComponent("MachineIdentifier"))
        try Data("vars".utf8).write(to: source.auxDirectory.appendingPathComponent("efi_vars.fd"))
        let lock = try #require(try source.tryLock())
        let clone = try FullClone.clone(holding: lock, to: dir.appendingPathComponent("W2.vmpane"), name: "W2")

        let a = try ConfigStore.load(source), b = try ConfigStore.load(clone)
        #expect(a.id != b.id)
        #expect(a.network[0].macAddress != b.network[0].macAddress)
        #expect(a.qemu?.smbiosUUID != b.qemu?.smbiosUUID)
        #expect(b.name == "W2")
        let fm = FileManager.default
        #expect(fm.fileExists(atPath: clone.currentDirectory.appendingPathComponent("disk.img").path))
        #expect(fm.fileExists(atPath: clone.auxDirectory.appendingPathComponent("efi_vars.fd").path))
        #expect(!fm.fileExists(atPath: clone.auxDirectory.appendingPathComponent("MachineIdentifier").path))
        #expect(try fm.contentsOfDirectory(atPath: clone.stateDirectory.path).isEmpty)
        #expect(try Generation.read(from: clone.generationURL) != Generation.read(from: source.generationURL))
    }
}

@Test func regeneratedIdentityDropsSavedState() throws {
    try withTempDirectory { dir in
        let bundle = try VMBundle.create(at: dir.appendingPathComponent("C.vmpane"), config: makeConfig())
        try Data("ram".utf8).write(to: bundle.stateDirectory.appendingPathComponent("suspend.vzvmsave"))
        let before = try ConfigStore.load(bundle)
        let lock = try #require(try bundle.tryLock())
        let after = try FullClone.regenerateIdentity(holding: lock)
        #expect(after.id != before.id)
        #expect(after.network[0].macAddress != before.network[0].macAddress)
        #expect(try ConfigStore.load(bundle) == after)
        #expect(try FileManager.default.contentsOfDirectory(atPath: bundle.stateDirectory.path).isEmpty)
    }
}

/// About 35 s: runs with `VMPANE_SLOW_TESTS=1` (the phase gate sets it).
@Test(.enabled(if: ProcessInfo.processInfo.environment["VMPANE_SLOW_TESTS"] != nil))
func thousandSnapshotCyclesStayFastAndFree() throws {
    try withTempDirectory { dir in
        let bundle = try VMBundle.create(at: dir.appendingPathComponent("P.vmpane"), config: makeConfig())
        let disk = bundle.currentDirectory.appendingPathComponent("disk.img")
        try DiskImage.createRaw(at: disk, sizeBytes: 64 << 30)
        let allocatedBefore = try DiskImage.allocatedBytes(disk)
        let store = SnapshotStore(lock: try #require(try bundle.tryLock()))
        let start = Date()
        for i in 0..<1000 {
            let meta = try store.create(name: "s\(i)", kind: .disk, origin: .user, context: context)
            try store.delete(meta.id)
        }
        let elapsed = Date().timeIntervalSince(start)
        #expect(elapsed < 60, "1000 cycles took \(elapsed) s")
        #expect(try DiskImage.allocatedBytes(disk) == allocatedBefore)
        print("snapshot create+delete: \(String(format: "%.1f", elapsed)) ms/cycle")
    }
}

@Test func plantedJournalCannotDeleteOutsideTheBundle() throws {
    try withTempDirectory { dir in
        let (bundle, lock) = try makeBundle(dir)
        let victim = dir.appendingPathComponent("victim", isDirectory: true)
        try FileManager.default.createDirectory(at: victim, withIntermediateDirectories: true)
        let journal = RestoreJournal(schemaVersion: 1, snapshotId: UUID(), staging: "../victim", newGenerationId: UUID())
        try DurableWrite.write(CanonicalJSON.encode(journal), to: bundle.restoreJournalURL)
        try SnapshotStore(lock: lock).recover()
        #expect(FileManager.default.fileExists(atPath: victim.path))
        #expect(!FileManager.default.fileExists(atPath: bundle.restoreJournalURL.path))
        #expect(try liveMarker(bundle) == "OLD")
    }
}

@Test func ramStateCanBeExcludedFromBackups() throws {
    try withTempDirectory { dir in
        let (bundle, _) = try makeBundle(dir)
        try BackupExclusion.apply(true, to: bundle)
        #expect(BackupExclusion.isExcluded(bundle.stateDirectory))
        var url = URL(fileURLWithPath: bundle.stateDirectory.path)
        url.removeAllCachedResourceValues()
        #expect(try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)  // what Time Machine sees
        try BackupExclusion.apply(false, to: bundle)
        #expect(!BackupExclusion.isExcluded(bundle.stateDirectory))
        try BackupExclusion.apply(false, to: bundle)  // clearing twice is fine
    }
}
