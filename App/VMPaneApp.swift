import SwiftUI
import VMPaneCore
import VMPaneUI

/// VMPane main app: the VM library (wizard, onboarding and preferences follow in Phase 08's later steps).
@main
struct VMPaneApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("VMPane", id: "library") {
            LibraryWindow(store: appDelegate.library)
                .frame(minWidth: 640, minHeight: 400)
        }
        Settings {
            PreferencesView(paths: appDelegate.supervisor.paths)
        }
        MenuBarExtra("VMPane", systemImage: "square.stack.3d.up") {
            MenuBarExtraView(store: appDelegate.library, killSwitch: appDelegate.killSwitch)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let supervisor = HelperSupervisor()
    lazy var library: LibraryStore = {
        let supervisor = supervisor
        return LibraryStore(
            library: VMLibrary(paths: supervisor.paths), links: HelperLinks(paths: supervisor.paths),
            launch: { bundle, headless in try await supervisor.launch(bundle, headless: headless) })
    }()

    lazy var killSwitch = AgentKillSwitch(paths: supervisor.paths)

    func applicationDidFinishLaunching(_ notification: Notification) {
        supervisor.start()
        killSwitch.registerHotKey()
    }

    /// A .vmpane bundle opened from Finder (double-click, Open With, or dropped on the Dock icon).
    func application(_ application: NSApplication, open urls: [URL]) {
        Task { await library.importBundles(urls) }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        Task { await library.reload() }
    }
}
