import SwiftUI
import VMPaneCore
import VMPaneUI

/// VMPane main app: VM library, wizard and settings (filled in by later phases).
@main
struct VMPaneApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("VMPane") {
            VStack(spacing: 8) {
                Text("VMPane").font(.largeTitle)
                Text("Version \(VMPane.version)").foregroundStyle(.secondary)
                Text("Apache-2.0").font(.footnote).foregroundStyle(.secondary)
            }
            .padding(40)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let supervisor = HelperSupervisor()

    func applicationDidFinishLaunching(_ notification: Notification) {
        supervisor.start()
    }
}
