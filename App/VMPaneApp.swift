import SwiftUI
import VMPaneCore
import VMPaneHost
import VMPaneUI

/// VMPane main app: the VM library (wizard, onboarding and preferences follow in Phase 08's later steps).
@main
struct VMPaneApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("VMPane", id: "library") {
            LibraryWindow(store: appDelegate.library)
                .frame(minWidth: 640, minHeight: 540)  // the New VM sheet (520) fits below the toolbar
        }
        .commands {
            CommandGroup(after: .appInfo) {
                if UpdaterController.isConfigured {
                    Button("Check for Updates…") { appDelegate.updater.checkForUpdates() }
                }
            }
        }
        Settings {
            TabView {
                PreferencesView(paths: appDelegate.supervisor.paths)
                    .tabItem { Label("General", systemImage: "gearshape") }
                AgentsPreferences(paths: appDelegate.supervisor.paths, killSwitch: appDelegate.killSwitch)
                    .tabItem { Label("AI Agents", systemImage: "sparkles") }
            }
            .frame(width: 520)
        }
        MenuBarExtra {
            MenuBarExtraView(store: appDelegate.library, killSwitch: appDelegate.killSwitch)
        } label: {
            MenuBarIcon(store: appDelegate.library)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let supervisor = HelperSupervisor()
    lazy var library: LibraryStore = {
        let supervisor = supervisor
        let store = LibraryStore(
            library: VMLibrary(paths: supervisor.paths), links: HelperLinks(paths: supervisor.paths),
            launch: { bundle, headless in try await supervisor.launch(bundle, headless: headless) })
        store.lowMemoryGuard = .alert { NSApp.keyWindow }
        return store
    }()

    lazy var killSwitch = AgentKillSwitch(paths: supervisor.paths)

    lazy var crashReports = CrashReports(paths: supervisor.paths, process: "app")
    lazy var updater = UpdaterController(store: library)

    func applicationDidFinishLaunching(_ notification: Notification) {
        crashReports.start()
        supervisor.start()
        updater.start()
        killSwitch.registerHotKey()
    }

    /// A .vmpane bundle opened from Finder (double-click, Open With, or dropped on the Dock icon) joins the library;
    /// a Parallels .pvm opens the import sheet; an installer (.iso, .ipsw) opens the new-VM sheet with it.
    func application(_ application: NSApplication, open urls: [URL]) {
        let installers = urls.filter { ["iso", "ipsw"].contains($0.pathExtension.lowercased()) }
        if let installer = installers.first { library.installerToUse = installer }
        if let pvm = urls.first(where: { $0.pathExtension.lowercased() == "pvm" }) { library.parallelsToImport = pvm }
        let rest = urls.filter { !installers.contains($0) }
        if !rest.isEmpty { Task { await library.importBundles(rest) } }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        Task { await library.reload() }
    }
}
