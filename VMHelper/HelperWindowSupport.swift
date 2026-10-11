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

    // Clipboard sharing runs only while the VM's window is the key window.
    func windowDidBecomeKey(_ notification: Notification) {
        let controller = controller
        Task { await controller.windowFocusChanged(true) }
    }

    func windowDidResignKey(_ notification: Notification) {
        let controller = controller
        Task { await controller.windowFocusChanged(false) }
    }
}

/// The Mac's general pasteboard, for the clipboard bridge (text, PNG, file URLs).
final class GeneralPasteboard: HostPasteboard {
    func changeCount() async -> Int { await MainActor.run { NSPasteboard.general.changeCount } }

    func read() async -> ClipboardContent {
        await MainActor.run {
            let pasteboard = NSPasteboard.general
            let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
            var png = pasteboard.data(forType: .png)
            if png == nil, let tiff = pasteboard.data(forType: .tiff) {
                png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
            }
            return ClipboardContent(text: pasteboard.string(forType: .string), png: png, files: urls.map(\.path))
        }
    }

    func write(_ content: ClipboardContent) async -> Int {
        await MainActor.run {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            if !content.files.isEmpty {
                pasteboard.writeObjects(content.files.map { URL(fileURLWithPath: $0) as NSURL })
            } else {
                if let text = content.text { pasteboard.setString(text, forType: .string) }
                if let png = content.png { pasteboard.setData(png, forType: .png) }
            }
            return pasteboard.changeCount
        }
    }
}

/// Asks the person whether an AI agent may go ahead (`mcp.confirmExec`): the command in a scrollable box, Deny
/// as the default, gone after the helper's minute without an answer.
@MainActor
enum ConfirmationDialog {
    static func ask(_ question: ConfirmationRequest) -> Bool {
        let alert = NSAlert()
        alert.messageText = question.title
        alert.informativeText = "Allow it this once? Check what it does first."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Deny")
        alert.addButton(withTitle: "Allow Once")
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 420, height: 90))
        text.string = question.detail
        text.isEditable = false
        text.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        let scroll = NSScrollView(frame: text.frame)
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        alert.accessoryView = scroll
        alert.window.level = .floating
        NSApp.activate()
        // The helper stops waiting after a minute (a no); the dialog goes too.
        let timeout = DispatchWorkItem { NSApp.abortModal() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: timeout)
        showing = true
        defer {
            timeout.cancel()
            showing = false
        }
        return alert.runModal() == .alertSecondButtonReturn
    }

    /// The helper asks one question at a time: this closes it (a no), e.g. when agents are stopped.
    static func dismiss() {
        if showing { NSApp.abortModal() }
    }

    private static var showing = false
}
