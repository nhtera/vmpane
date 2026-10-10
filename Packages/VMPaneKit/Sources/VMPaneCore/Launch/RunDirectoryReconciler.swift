import Foundation

/// Cleans up after helpers that died without cleaning up (crash, `kill -9`). Run by the app every 30 s,
/// by the CLI before connecting and by each helper at start.
///
/// A VM's run files are only touched after its bundle lock is taken, so a live helper is never disturbed.
/// If the lock is busy but the recorded helper is dead, its orphaned children hold the lock: they are
/// reaped (after pid + start time + path match) and the files removed.
public enum RunDirectoryReconciler {
    public struct Outcome: Equatable, Sendable {
        public var cleaned: [ShortID] = []
        public var reapedChildren: [ProcessRecord] = []
    }

    @discardableResult
    public static func reconcile(paths: VMPanePaths) -> Outcome {
        var outcome = Outcome()
        let entries = (try? FileManager.default.contentsOfDirectory(at: paths.runDirectory, includingPropertiesForKeys: nil)) ?? []
        for url in entries where url.pathExtension == "pid" {
            guard let sid = ShortID(rawValue: url.deletingPathExtension().lastPathComponent) else { continue }
            let run = RunFiles(paths: paths, sid: sid)
            // Unreadable (or from a newer VMPane): its owner may be alive, and without the bundle path its
            // lock cannot be checked. Leave it.
            guard let helper = run.readHelper() else { continue }
            if helper.process.isAlive { continue }
            func reapOrphans() -> Bool {
                // Re-read: a new helper may have taken over since; only the dead helper's children are reaped.
                guard run.readHelper() == helper else { return false }
                let orphans = run.readChildEntries().filter { $0.parent.matches(helper.process) && $0.process.isAlive }
                outcome.reapedChildren += orphans.map(\.process)
                return run.reapChildren(of: helper.process).isEmpty
            }
            guard let bundle = try? VMBundle.open(URL(fileURLWithPath: helper.bundlePath)) else {
                // Bundle gone (deleted or moved): its lock cannot be taken; verified children can still be stopped.
                if reapOrphans() {
                    run.removeAll()
                    outcome.cleaned.append(sid)
                }
                continue
            }
            var lock = try? bundle.tryLock()
            if lock == nil {
                guard reapOrphans() else { continue }
                lock = try? bundle.tryLock(retryingFor: 2)
            }
            guard let lock else { continue }
            guard run.readHelper() == helper else {  // a new helper started meanwhile
                lock.release()
                continue
            }
            run.removeAll()
            lock.release()
            outcome.cleaned.append(sid)
        }
        return outcome
    }
}
