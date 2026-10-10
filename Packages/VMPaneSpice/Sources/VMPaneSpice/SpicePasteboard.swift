import AppKit
@preconcurrency import CocoaSpice
import VMPaneCore
import VMPaneQEMU

/// The Mac side of SPICE clipboard sharing (through spice-vdagent in the guest), text only, in the directions the
/// VM's `clipboard.mode` allows, and only while the VM's window is the key window: the guest can neither read the
/// Mac's clipboard nor replace it while the user works elsewhere.
/// CocoaSpice calls it on the SPICE main loop thread; NSPasteboard is thread-safe for these calls.
final class SpicePasteboard: NSObject, CSPasteboardDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var mode: ClipboardConfig.Mode = .off
    private var focused = false
    private var changeCount = NSPasteboard.general.changeCount

    func update(mode: ClipboardConfig.Mode, focused: Bool) {
        lock.withLock {
            self.mode = mode
            self.focused = focused
        }
    }

    private var canSend: Bool { lock.withLock { focused && mode.sendsToGuest } }
    private var canReceive: Bool { lock.withLock { focused && mode.receivesFromGuest } }

    /// Offers the Mac's clipboard to the guest when it changed since the last offer (called on focus and by a
    /// timer while focused; CocoaSpice observes the notification).
    func offerIfChanged() {
        let current = NSPasteboard.general.changeCount
        let changed = lock.withLock { () -> Bool in
            defer { changeCount = current }
            return current != changeCount
        }
        if changed, canSend { NotificationCenter.default.post(name: .csPasteboardChanged, object: nil) }
    }

    func canReadItem(for type: CSPasteboardType) -> Bool {
        type == .string && canSend && NSPasteboard.general.string(forType: .string) != nil
    }

    func data(for type: CSPasteboardType) -> Data? {
        guard type == .string, canSend else { return nil }
        return NSPasteboard.general.string(forType: .string).map { Data($0.utf8) }
    }

    func setData(_ data: Data, for type: CSPasteboardType) {
        guard type == .string, let string = String(data: data, encoding: .utf8) else { return }
        setString(string)
    }

    func string() -> String? {
        canSend ? NSPasteboard.general.string(forType: .string) : nil
    }

    func setString(_ string: String) {
        guard canReceive else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
        lock.withLock { changeCount = pasteboard.changeCount }  // not offered back to the guest
    }

    /// The guest dropped its clipboard: the Mac keeps its own.
    func clearContents() {}
}
