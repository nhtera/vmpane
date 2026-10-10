import Foundation
import VMPaneCore

/// The app's view of helpers: cleans up after dead ones every 30 s and launches new ones from the
/// versioned runtime copy, so an app update never replaces a binary a running VM uses.
@MainActor
final class HelperSupervisor {
    static let reconcileInterval: TimeInterval = 30

    let paths: VMPanePaths
    private var timer: Timer?
    private var reconciling = false

    init(paths: VMPanePaths = .standard()) {
        self.paths = paths
    }

    func start() {
        reconcile()
        timer = Timer.scheduledTimer(withTimeInterval: Self.reconcileInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reconcile() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Runs on the blocking queue (reaping a dead helper's children can wait seconds); ticks never overlap.
    func reconcile() {
        guard !reconciling else { return }
        reconciling = true
        let paths = paths
        Task {
            await Blocking.run {
                RunDirectoryReconciler.reconcile(paths: paths)
                try? RuntimeStore(paths: paths).garbageCollect(
                    keep: [RuntimeStore.version(app: Bundle.main.bundleURL, appVersion: VMPane.version)])
            }
            reconciling = false
        }
    }

    /// Starts the helper for `bundle` (its own process, Dock tile and window).
    func launch(_ bundle: VMBundle, headless: Bool) throws {
        let runtime = try RuntimeStore(paths: paths)
            .ensure(
                version: RuntimeStore.version(app: Bundle.main.bundleURL, appVersion: VMPane.version),
                items: RuntimeStore.helperItems(app: Bundle.main.bundleURL)
            )
            .appendingPathComponent("VMPaneVM.app", isDirectory: true)
        let config = try ConfigStore.load(bundle)
        try LaunchCoordinator.checkMacOSGuestLimit(starting: config.os, paths: paths) { record in
            (try? VMBundle.open(URL(fileURLWithPath: record.bundlePath))).flatMap { try? ConfigStore.load($0).os }
        }
        try LaunchCoordinator.launchHelper(runtimeHelper: runtime, bundle: bundle, headless: headless)
    }
}
