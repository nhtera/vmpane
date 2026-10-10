import Darwin
import Foundation
import Testing

@testable import VMPaneCore

/// Spawns `/bin/sleep 300`, optionally keeping `lock` open in it (as a disk-writing child would).
private func spawnSleeper(holding lock: BundleLock? = nil) throws -> ProcessRecord {
    try ChildSpawner.spawn(
        URL(fileURLWithPath: "/bin/sleep"),
        .init(arguments: ["300"], inheriting: lock.map { [$0.fileDescriptor] } ?? []))
}

private func kill9(_ record: ProcessRecord) {
    kill(record.pid, SIGKILL)
    var status: Int32 = 0
    waitpid(record.pid, &status, 0)
}

private func makePrepared(_ dir: URL) throws -> (VMBundle, VMPanePaths) {
    let paths = VMPanePaths(root: dir.appendingPathComponent("support"))
    let bundle = try VMBundle.create(at: dir.appendingPathComponent("A.vmpane"), config: makeConfig())
    return (bundle, paths)
}

@Test func processRecordsMatchOnlyTheExactProcess() throws {
    #expect(ProcessRecord.this.isAlive)
    let sleeper = try spawnSleeper()
    defer { kill9(sleeper) }
    var reused = sleeper
    reused.startTime -= 1  // same pid, different start time: a reused pid
    #expect(!reused.isAlive)
    #expect(reused.terminate())  // "gone" as far as the record goes…
    #expect(sleeper.isAlive)  // …and the unrelated process was not signalled
    #expect(sleeper.terminate())
    #expect(!sleeper.isAlive)
}

@Test func unrelatedChildrenDoNotPinTheLock() throws {
    try withTempDirectory { dir in
        let (bundle, _) = try makePrepared(dir)
        let lock = try #require(try bundle.tryLock())
        let bystander = try spawnSleeper()
        defer { kill9(bystander) }
        lock.release()
        // A pinning child would still hold it after a second (it sleeps 300 s); a brief hold by a process
        // another test is launching would not.
        #expect(try bundle.tryLock(retryingFor: 1) != nil)
    }
}

@Test func secondHelperIsRefused() throws {
    try withTempDirectory { dir in
        let (bundle, paths) = try makePrepared(dir)
        let helperA = try spawnSleeper()
        defer { kill9(helperA) }
        let prepared = try LaunchCoordinator.prepareBundle(bundle, paths: paths, runtimeVersion: "1", process: helperA)
        defer { prepared.lock.release() }
        #expect(throws: LaunchError.alreadyRunning(pid: helperA.pid)) {
            try LaunchCoordinator.prepareBundle(bundle, paths: paths, runtimeVersion: "1")
        }
        #expect(prepared.runFiles.readHelper()?.process == helperA)
    }
}

@Test func relaunchAfterKill9ReapsTheOrphanedChildFirst() throws {
    try withTempDirectory { dir in
        let (bundle, paths) = try makePrepared(dir)
        let helper = try spawnSleeper()
        let prepared = try LaunchCoordinator.prepareBundle(bundle, paths: paths, runtimeVersion: "1", process: helper)
        let child = try spawnSleeper(holding: prepared.lock)
        try prepared.runFiles.writeChildren([child], parent: helper)
        prepared.lock.release()  // the helper's own descriptor goes with it…
        kill9(helper)  // …but the child still holds the lock
        #expect(try bundle.tryLock() == nil)

        let relaunched = try LaunchCoordinator.prepareBundle(bundle, paths: paths, runtimeVersion: "2")
        defer { relaunched.lock.release() }
        #expect(!child.isAlive)
        #expect(relaunched.runFiles.readChildren().isEmpty)
        #expect(relaunched.runFiles.readHelper()?.process == ProcessRecord.this)
        #expect(relaunched.runFiles.readHelper()?.runtimeVersion == "2")
    }
}

@Test func reconcilerCleansDeadHelpersOnly() throws {
    try withTempDirectory { dir in
        let (bundle, paths) = try makePrepared(dir)
        // A live helper: left alone.
        let live = try spawnSleeper()
        defer { kill9(live) }
        let prepared = try LaunchCoordinator.prepareBundle(bundle, paths: paths, runtimeVersion: "1", process: live)
        FileManager.default.createFile(atPath: prepared.runFiles.socketURL.path, contents: nil)
        #expect(RunDirectoryReconciler.reconcile(paths: paths).cleaned.isEmpty)
        #expect(FileManager.default.fileExists(atPath: prepared.runFiles.pidURL.path))

        // The helper dies with an orphaned child holding the lock: child reaped, files removed.
        let child = try spawnSleeper(holding: prepared.lock)
        try prepared.runFiles.writeChildren([child], parent: live)
        prepared.lock.release()
        kill9(live)
        let outcome = RunDirectoryReconciler.reconcile(paths: paths)
        #expect(outcome.cleaned == [prepared.runFiles.sid])
        #expect(outcome.reapedChildren == [child])
        #expect(!child.isAlive)
        for url in [prepared.runFiles.pidURL, prepared.runFiles.socketURL, prepared.runFiles.childrenURL] {
            #expect(!FileManager.default.fileExists(atPath: url.path))
        }
        #expect(try bundle.tryLock() != nil)
    }
}

@Test func macOSGuestLimitCountsLiveHelpers() throws {
    try withTempDirectory { dir in
        let paths = VMPanePaths(root: dir.appendingPathComponent("support"))
        var sleepers: [ProcessRecord] = []
        defer { sleepers.forEach(kill9) }
        for name in ["M1", "M2"] {
            let bundle = try VMBundle.create(at: dir.appendingPathComponent("\(name).vmpane"), config: makeConfig(os: .macos))
            let sleeper = try spawnSleeper()
            sleepers.append(sleeper)
            let prepared = try LaunchCoordinator.prepareBundle(bundle, paths: paths, runtimeVersion: "1", process: sleeper)
            prepared.lock.release()
        }
        #expect(LaunchCoordinator.liveHelpers(paths: paths).count == 2)
        #expect(throws: LaunchError.tooManyMacOSGuests(limit: 2)) {
            try LaunchCoordinator.checkMacOSGuestLimit(starting: .macos, paths: paths) { _ in .macos }
        }
        try LaunchCoordinator.checkMacOSGuestLimit(starting: .linux, paths: paths) { _ in .macos }
    }
}

@Test func runtimeStoreClonesOnceAndCollectsUnusedVersions() throws {
    try withTempDirectory { dir in
        let paths = VMPanePaths(root: dir.appendingPathComponent("support"))
        let app = dir.appendingPathComponent("VMPaneVM.app/Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try Data("binary".utf8).write(to: app.appendingPathComponent("VMPaneVM"))
        let store = RuntimeStore(paths: paths)
        let source = dir.appendingPathComponent("VMPaneVM.app")
        let first = try store.ensure(version: "1", helperApp: source)
        #expect(try store.ensure(version: "1", helperApp: source) == first)
        _ = try store.ensure(version: "2", helperApp: source)
        func versions() throws -> [String] {
            try FileManager.default.contentsOfDirectory(atPath: paths.runtimeDirectory.path).filter { !$0.hasPrefix(".") }.sorted()
        }
        try store.garbageCollect(keep: ["2"])
        #expect(try versions() == ["1", "2"])  // too young: a helper may be starting from it
        try store.garbageCollect(keep: ["2"], now: Date().addingTimeInterval(RuntimeStore.minimumAge + 60))
        #expect(try versions() == ["2"])
    }
}

@Test func runtimeStoreCopiesTheHelperAndQEMU() throws {
    try withTempDirectory { dir in
        let paths = VMPanePaths(root: dir.appendingPathComponent("support"))
        let app = dir.appendingPathComponent("VMPane.app", isDirectory: true)
        let files = [
            "Contents/Helpers/VMPaneVM.app/Contents/MacOS/VMPaneVM", "Contents/Helpers/qemu/bin/qemu-system-aarch64",
            "Contents/Helpers/qemu/lib/libglib-2.0.0.dylib", "Contents/Resources/qemu/share/edk2-aarch64-code.fd",
        ]
        for file in files {
            let url = app.appendingPathComponent(file)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(file.utf8).write(to: url)
        }
        let store = RuntimeStore(paths: paths)
        let runtime = try store.ensure(version: "1", items: RuntimeStore.helperItems(app: app))
        for (copy, original) in [
            ("VMPaneVM.app/Contents/MacOS/VMPaneVM", files[0]), ("qemu/bin/qemu-system-aarch64", files[1]),
            ("qemu/lib/libglib-2.0.0.dylib", files[2]), ("qemu/share/edk2-aarch64-code.fd", files[3]),
        ] {
            #expect(try String(contentsOf: runtime.appendingPathComponent(copy), encoding: .utf8) == original)
        }
        // An app without QEMU (a Debug build without the QEMU bundle) still gets its helper copied.
        try FileManager.default.removeItem(at: app.appendingPathComponent("Contents/Helpers/qemu"))
        try FileManager.default.removeItem(at: app.appendingPathComponent("Contents/Resources"))
        #expect(RuntimeStore.helperItems(app: app).map(\.path) == ["VMPaneVM.app"])
        let second = try store.ensure(version: "2", items: RuntimeStore.helperItems(app: app))
        #expect(FileManager.default.fileExists(atPath: second.appendingPathComponent("VMPaneVM.app").path))
        #expect(!FileManager.default.fileExists(atPath: second.appendingPathComponent("qemu").path))
    }
}

@Test func runtimeVersionFollowsTheQEMUBundle() throws {
    try withTempDirectory { dir in
        let app = dir.appendingPathComponent("VMPane.app", isDirectory: true)
        #expect(RuntimeStore.version(app: app, appVersion: "1.2") == "1.2")
        let manifest = app.appendingPathComponent("Contents/Resources/qemu/MANIFEST.json")
        try FileManager.default.createDirectory(at: manifest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{\"a\":1}".utf8).write(to: manifest)
        let first = RuntimeStore.version(app: app, appVersion: "1.2")
        #expect(first.hasPrefix("1.2-q") && first.count == "1.2-q".count + 8)
        try Data("{\"a\":2}".utf8).write(to: manifest)
        #expect(RuntimeStore.version(app: app, appVersion: "1.2") != first)

        let paths = VMPanePaths(root: dir.appendingPathComponent("support"))
        let store = RuntimeStore(paths: paths)
        let helper = paths.runtime(version: first).appendingPathComponent("VMPaneVM.app", isDirectory: true)
        #expect(store.version(ofHelperAt: helper) == first)
        #expect(store.version(ofHelperAt: app.appendingPathComponent("Contents/Helpers/VMPaneVM.app")) == nil)
    }
}

@Test func childrenStopOnSIGTERMEvenIfTheParentIgnoresIt() throws {
    let previous = signal(SIGTERM, SIG_IGN)
    defer { signal(SIGTERM, previous) }
    let child = try ChildSpawner.spawn(URL(fileURLWithPath: "/bin/sleep"), .init(arguments: ["300"]))
    let start = Date()
    #expect(child.terminate(grace: 3))
    #expect(Date().timeIntervalSince(start) < 1, "the child ignored SIGTERM and needed SIGKILL")
}

@Test func finderCopyGetsItsOwnIdentityAndLeavesTheOriginalAlone() throws {
    try withTempDirectory { dir in
        let paths = VMPanePaths(root: dir.appendingPathComponent("support"))
        try FileManager.default.createDirectory(at: paths.defaultLibrary, withIntermediateDirectories: true)
        let library = VMLibrary(paths: paths)
        let original = try VMBundle.create(at: paths.defaultLibrary.appendingPathComponent("O.vmpane"), config: makeConfig())
        try library.register(original)
        let copyURL = paths.defaultLibrary.appendingPathComponent("O copy.vmpane")
        try FileManager.default.copyItem(at: original.url, to: copyURL)

        // The original runs, with a child holding its lock.
        let helper = try spawnSleeper()
        defer { kill9(helper) }
        let running = try LaunchCoordinator.prepareBundle(original, paths: paths, runtimeVersion: "1", process: helper, library: library)
        let child = try spawnSleeper(holding: running.lock)
        defer { kill9(child) }
        try running.runFiles.writeChildren([child], parent: helper)

        let copy = try LaunchCoordinator.prepareBundle(try VMBundle.open(copyURL), paths: paths, runtimeVersion: "1", library: library)
        defer { copy.lock.release() }
        #expect(copy.config.id != running.config.id)
        #expect(copy.runFiles.sid != running.runFiles.sid)
        #expect(copy.config.network[0].macAddress != running.config.network[0].macAddress)
        #expect(child.isAlive, "the original VM's child must not be reaped")
        #expect(running.runFiles.readHelper()?.process == helper)
        running.lock.release()
    }
}

/// A freshly compiled sleeper: an ordinary third-party binary, like QEMU. (Copies of Apple's own binaries
/// are held at exec by the system on some Macs and cannot be killed, so they are not used here.)
private func buildSleeper(in dir: URL) throws -> URL {
    let source = dir.appendingPathComponent("sleeper.c")
    try "#include <unistd.h>\nint main(void) { for (;;) pause(); }\n".write(to: source, atomically: true, encoding: .utf8)
    let binary = dir.appendingPathComponent("sleeper")
    try shell("/usr/bin/xcrun", ["clang", "-o", binary.path, source.path])
    return binary
}

@Test func aProcessWhoseBinaryWasDeletedIsStillAliveAndStoppable() throws {
    try withTempDirectory { dir in
        let binary = try buildSleeper(in: dir)
        let child = try ChildSpawner.spawn(binary)
        usleep(300_000)  // let it finish loading: real deletions (runtime GC) happen long after start
        try FileManager.default.removeItem(at: binary)
        #expect(child.isAlive)  // whether or not the kernel can still report the deleted path
        #expect(child.terminate())
        #expect(!child.isAlive)
    }
}

@Test func unreadablePidFilesAreLeftAlone() throws {
    try withTempDirectory { dir in
        let paths = VMPanePaths(root: dir.appendingPathComponent("support"))
        let run = RunFiles(paths: paths, sid: ShortID(UUID()))
        try run.ensureRunDirectory()
        try Data(#"{"schemaVersion": 99, "future": true}"#.utf8).write(to: run.pidURL)
        FileManager.default.createFile(atPath: run.socketURL.path, contents: nil)
        #expect(RunDirectoryReconciler.reconcile(paths: paths).cleaned.isEmpty)
        #expect(FileManager.default.fileExists(atPath: run.pidURL.path))
        #expect(FileManager.default.fileExists(atPath: run.socketURL.path))
    }
}

@Test func reapingTouchesOnlyTheDeadHelpersChildren() throws {
    try withTempDirectory { dir in
        let run = RunFiles(paths: VMPanePaths(root: dir), sid: ShortID(UUID()))
        let deadHelper = try spawnSleeper()
        let newHelper = try spawnSleeper()
        defer { kill9(newHelper) }
        let orphan = try spawnSleeper()
        let newChild = try spawnSleeper()
        defer { kill9(newChild) }
        let encoder = JSONEncoder()
        let lines = try [RunFiles.ChildEntry(process: orphan, parent: deadHelper), .init(process: newChild, parent: newHelper)]
            .map { String(bytes: try encoder.encode($0), encoding: .utf8) ?? "" }
        try run.ensureRunDirectory()
        try (lines.joined(separator: "\n") + "\n").write(to: run.childrenURL, atomically: true, encoding: .utf8)
        kill9(deadHelper)
        #expect(run.reapChildren(of: deadHelper).isEmpty)
        #expect(!orphan.isAlive)
        #expect(newChild.isAlive)
    }
}

@Test func suspendedSpawnRunsOnlyAfterResume() throws {
    try withTempDirectory { dir in
        let marker = dir.appendingPathComponent("ran")
        let child = try ChildSpawner.spawnSuspended(URL(fileURLWithPath: "/usr/bin/touch"), .init(arguments: [marker.path]))
        usleep(200_000)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        ChildSpawner.resume(child)
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: marker.path) { usleep(10_000) }
        #expect(FileManager.default.fileExists(atPath: marker.path))
        var status: Int32 = 0
        waitpid(child.pid, &status, 0)
    }
}
