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

    /// The runtime this app launches helpers from now (its version and its files' identity, changed by a rebuild).
    nonisolated static func currentRuntime() -> String {
        RuntimeStore.version(app: Bundle.main.bundleURL, appVersion: VMPane.version)
    }

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
                try? RuntimeStore(paths: paths).garbageCollect(keep: [HelperSupervisor.currentRuntime()])
            }
            reconciling = false
        }
    }

    /// Starts the helper for `bundle` (its own process, Dock tile and window).
    func launch(_ bundle: VMBundle, headless: Bool) throws {
        try LaunchCoordinator.launch(bundle, app: Bundle.main.bundleURL, appVersion: VMPane.version, paths: paths, headless: headless)
    }
}
