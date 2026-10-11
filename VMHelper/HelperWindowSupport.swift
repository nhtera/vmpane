import AppKit
import VMPaneHost
import VMPaneUI

/// A menu item that runs a closure (the Dock menu has no responder chain to target).
@MainActor
final class DockMenuItem: NSMenuItem {
    private let run: @MainActor () -> Void

    init(title: String, action: @escaping @MainActor () -> Void) {
        run = action
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func fire() { run() }
}

/// Closing a VM window does what the VM's close action says (keep running in the background, suspend, or shut
/// down) and only hides the window: it shows the guest, which keeps running behind it.
@MainActor
final class WindowCloser: NSObject, NSWindowDelegate {
    let model: HelperViewModel
    let controller: HelperController
    let hide: @MainActor () -> Void

    init(model: HelperViewModel, controller: HelperController, hide: @escaping @MainActor () -> Void) {
        self.model = model
        self.controller = controller
        self.hide = hide
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hide()
        let (model, controller) = (model, controller)
        Task {
            switch await controller.currentConfig.ui.closeAction {
            case .keepRunning: break
            case .suspend: await model.perform(.suspend)
            case .stop: await model.perform(.shutDown)
            }
        }
        return false
    }
}
