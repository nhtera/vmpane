import AppKit
import Sparkle
import VMPaneUI

/// Updates through Sparkle 2 (Red Team #5): an EdDSA-signed appcast, stable or (opt-in) beta channel.
///
/// Running VMs are safe whatever happens to the app bundle: helpers run from their versioned runtime copies.
/// Still, VMPane never installs an update silently (`SUAutomaticallyUpdate` is off: Sparkle's install-on-quit
/// postponement is unverified), and when VMs run, the relaunch waits for the person's choice: update now (VMs
/// keep the old version until restarted), suspend them all and update (they resume after the relaunch), or later.
/// Without a feed and key in Info.plist (development builds) the updater stays off.
@MainActor
final class UpdaterController: NSObject {
    nonisolated static let betaKey = "updates.beta"
    /// VMs suspended for an update, started again once the new version runs.
    static let resumeKey = "updates.resumeAfterRelaunch"

    let store: LibraryStore
    private var controller: SPUStandardUpdaterController?

    init(store: LibraryStore) {
        self.store = store
        super.init()
    }

    static var isConfigured: Bool {
        let info = Bundle.main.infoDictionary ?? [:]
        return !((info["SUFeedURL"] as? String) ?? "").isEmpty && !((info["SUPublicEDKey"] as? String) ?? "").isEmpty
    }

    var canCheck: Bool { controller != nil }

    func start() {
        guard Self.isConfigured else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
        resumeSuspended()
    }

    func checkForUpdates() { controller?.checkForUpdates(nil) }

    /// The VMs suspended for the last update.
    private func resumeSuspended() {
        let ids = (UserDefaults.standard.stringArray(forKey: Self.resumeKey) ?? []).compactMap(UUID.init(uuidString:))
        UserDefaults.standard.removeObject(forKey: Self.resumeKey)
        guard !ids.isEmpty else { return }
        Task {
            await store.reload()
            for id in ids { await store.perform(.start(headless: false), on: id) }
        }
    }

    /// The person's answer when VMs run; `install` relaunches into the new version.
    fileprivate func askBeforeRelaunch(_ version: String, install: @escaping () -> Void) -> Bool {
        let running = store.rows.filter(\.isRunning)
        guard !running.isEmpty else { return false }
        let alert = NSAlert()
        alert.messageText = "Install VMPane \(version) now?"
        alert.informativeText =
            "\(running.count == 1 ? "A VM is" : "\(running.count) VMs are") running. They keep running on the current version until you "
            + "restart them, or VMPane can suspend them and resume them after the update."
        alert.addButton(withTitle: "Update Now")
        alert.addButton(withTitle: "Suspend All and Update")
        alert.addButton(withTitle: "Later")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            install()
        case .alertSecondButtonReturn:
            Task { await suspendThenInstall(running.map(\.id), install: install) }
        default:
            break  // Sparkle offers it again at the next check
        }
        return true
    }

    private func suspendThenInstall(_ ids: [UUID], install: @escaping () -> Void) async {
        UserDefaults.standard.set(ids.map(\.uuidString), forKey: Self.resumeKey)
        for id in ids { await store.perform(.suspend, on: id) }
        var waited = 0
        while ids.contains(where: running), waited < 240 {  // up to 2 minutes
            try? await Task.sleep(for: .milliseconds(500))
            waited += 1
        }
        if ids.contains(where: running) {
            UserDefaults.standard.removeObject(forKey: Self.resumeKey)
            let alert = NSAlert()
            alert.messageText = "Not every VM could be suspended"
            alert.informativeText = "The update waits. Shut the remaining VMs down, or choose Update Now."
            alert.runModal()
            return
        }
        install()
    }

    private func running(_ id: UUID) -> Bool { store.rows.first { $0.id == id }?.isRunning ?? false }
}

extension UpdaterController: SPUUpdaterDelegate {
    nonisolated func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        UserDefaults.standard.bool(forKey: Self.betaKey) ? ["beta"] : []
    }

    nonisolated func updater(
        _ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem, untilInvokingBlock installHandler: @escaping () -> Void
    ) -> Bool {
        let version = item.displayVersionString
        let install = UncheckedHandler(installHandler)
        return MainActor.assumeIsolated { askBeforeRelaunch(version) { install.call() } }
    }
}

/// Sparkle calls its blocks on the main thread.
private struct UncheckedHandler: @unchecked Sendable {
    let call: () -> Void
    init(_ call: @escaping () -> Void) { self.call = call }
}
