import AppKit
import VMPaneCore
import VMPaneHost

/// Per-VM helper app: one process per running VM, with its own Dock tile and window.
/// The VM lifecycle, control socket and display are added in later phases.
@main
@MainActor
final class HelperDelegate: NSObject, NSApplicationDelegate {
    static func main() {
        let app = NSApplication.shared
        let delegate = HelperDelegate()
        app.delegate = delegate
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Nothing to run yet; quit so a stray launch does not linger.
        NSApp.terminate(nil)
    }
}
