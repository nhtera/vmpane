import Foundation

public enum LaunchError: Error, Equatable, Sendable, CustomStringConvertible {
    /// A live helper already owns this VM (the helper exits with `alreadyRunningExitCode`).
    case alreadyRunning(pid: Int32)
    /// The bundle lock is held but no helper or child we know of holds it.
    case lockedByUnknownProcess
    /// Children of a dead helper did not exit.
    case orphansSurvived([ProcessRecord])
    case tooManyMacOSGuests(limit: Int)

    public var description: String {
        switch self {
        case .alreadyRunning(let pid): "This VM is already running (process \(pid))."
        case .lockedByUnknownProcess: "Another program has this VM open."
        case .orphansSurvived(let records):
            "Processes left by this VM's last run did not exit (\(records.map { String($0.pid) }.joined(separator: ", ")))."
        case .tooManyMacOSGuests(let limit):
            "macOS allows \(limit) macOS virtual machines running at once on a Mac. Shut one down to start this one."
        }
    }
}

/// A bundle opened by its helper: locked, recovered, migrated, and registered in the run directory.
public struct PreparedBundle: Sendable {
    public let lock: BundleLock
    public let config: VMConfigV1
    public let runFiles: RunFiles
    /// The bundle duplicated another VM (e.g. a Finder copy) and got a new identity: tell the user.
    public let identityRegenerated: Bool
    /// The helper process this bundle was prepared for (recorded as the parent of its children).
    public let owner: ProcessRecord

    /// The same bundle with a configuration saved under its lock since it was prepared.
    public func replacing(config: VMConfigV1) -> PreparedBundle {
        PreparedBundle(lock: lock, config: config, runFiles: runFiles, identityRegenerated: identityRegenerated, owner: owner)
    }
}

/// Launch and reap rules shared by the app, the CLI and the helper.
public enum LaunchCoordinator {
    /// `EX_TEMPFAIL`: another helper owns the VM.
    public static let alreadyRunningExitCode: Int32 = 75
    /// Apple's licence and Virtualization.framework allow two macOS guests per Mac.
    public static let macOSGuestLimit = 2

    /// Helper start-up, before binding the socket:
    /// 1. take `bundle.lock`; if busy, either a live helper owns the VM (`alreadyRunning`) or a dead
    ///    helper's children still hold it, and exactly those children are reaped before retrying;
    /// 2. replay an interrupted restore, sweep leftovers, migrate the config;
    /// 3. a bundle that duplicates another VM (same id or MAC, e.g. a Finder copy) gets its own identity;
    ///    the other VM's run files are never touched;
    /// 4. reap the children the previous (dead) helper of this bundle recorded, and wait for them;
    /// 5. write the pid file.
    public static func prepareBundle(
        _ bundle: VMBundle, paths: VMPanePaths, runtimeVersion: String,
        process: ProcessRecord = .this, library: VMLibrary? = nil
    ) throws -> PreparedBundle {
        var run = RunFiles(paths: paths, sid: ShortID(try ConfigStore.load(bundle).id))
        func ownedHelper(_ run: RunFiles) -> HelperRecord? {
            run.readHelper().flatMap { $0.bundlePath == bundle.url.path ? $0 : nil }
        }

        let lock = try acquireLock(bundle, run: run, process: process)

        try SnapshotStore(lock: lock).recover()
        var config = try ConfigStore.loadAndMigrate(lock)
        var regenerated = false
        if let other = run.readHelper(), other.bundlePath != bundle.url.path {
            // Our sid belongs to another bundle's helper: we are a copy of that VM.
            config = try FullClone.regenerateIdentity(holding: lock)
            regenerated = true
        }
        if let library {
            let adopted = try library.adopt(holding: lock)
            regenerated = regenerated || adopted.regenerated
            config = adopted.config
        }
        if regenerated {
            run = RunFiles(paths: paths, sid: ShortID(config.id))
        }
        // We hold the lock, so a previous helper of this bundle is dead: stop what it left running.
        if let previous = ownedHelper(run), !previous.process.matches(process) {
            let survivors = run.reapChildren(of: previous.process)
            if !survivors.isEmpty { throw LaunchError.orphansSurvived(survivors) }
        }
        run.removeAll()
        try run.writeHelper(
            HelperRecord(
                process: process, runtimeVersion: runtimeVersion, bundlePath: bundle.url.path,
                vmId: config.id))
        return PreparedBundle(lock: lock, config: config, runFiles: run, identityRegenerated: regenerated, owner: process)
    }

    /// Takes the bundle lock. Busy means a live helper owns the VM (`alreadyRunning`), or a dead helper's
    /// orphaned children hold it: exactly those are reaped (the pid record is re-read first, so a helper
    /// that took over meanwhile is not mistaken for the dead one) before retrying.
    private static func acquireLock(_ bundle: VMBundle, run: RunFiles, process: ProcessRecord) throws -> BundleLock {
        if let lock = try bundle.tryLock() { return lock }
        let helper = run.readHelper().flatMap { $0.bundlePath == bundle.url.path ? $0 : nil }
        if let helper, !helper.process.matches(process) {
            if helper.process.isAlive { throw LaunchError.alreadyRunning(pid: helper.process.pid) }
            guard run.readHelper() == helper else { throw LaunchError.lockedByUnknownProcess }
            let survivors = run.reapChildren(of: helper.process)
            if !survivors.isEmpty { throw LaunchError.orphansSurvived(survivors) }
        }
        guard let lock = try bundle.tryLock(retryingFor: 2) else { throw LaunchError.lockedByUnknownProcess }
        return lock
    }

    /// Live helpers in the run directory.
    public static func liveHelpers(paths: VMPanePaths) -> [HelperRecord] {
        let entries = (try? FileManager.default.contentsOfDirectory(at: paths.runDirectory, includingPropertiesForKeys: nil)) ?? []
        return entries.filter { $0.pathExtension == "pid" }.compactMap { url in
            guard let sid = ShortID(rawValue: url.deletingPathExtension().lastPathComponent),
                let record = RunFiles(paths: paths, sid: sid).readHelper(), record.process.isAlive
            else { return nil }
            return record
        }
    }

    /// Refuses a third macOS guest. `osOf` maps a live helper's VM to its guest OS.
    public static func checkMacOSGuestLimit(
        starting os: GuestOS, paths: VMPanePaths,
        osOf: (HelperRecord) -> GuestOS?
    ) throws {
        guard os == .macos else { return }
        let running = liveHelpers(paths: paths).filter { osOf($0) == .macos }.count
        if running >= macOSGuestLimit { throw LaunchError.tooManyMacOSGuests(limit: macOSGuestLimit) }
    }

    /// Launches a helper for `bundle` from the runtime copy, as its own app instance (own Dock tile).
    /// (posix_spawn, not Foundation's `Process`, which forks and briefly copies every descriptor.)
    public static func launchHelper(runtimeHelper: URL, bundle: VMBundle, headless: Bool) throws {
        let arguments = ["-n", runtimeHelper.path, "--args", "--vm", bundle.url.path] + (headless ? ["--headless"] : [])
        let opener = try ChildSpawner.spawn(URL(fileURLWithPath: "/usr/bin/open"), .init(arguments: arguments))
        var status: Int32 = 0
        guard waitpid(opener.pid, &status, 0) == opener.pid, status == 0 else { throw POSIXError(.ECHILD) }
    }
}
