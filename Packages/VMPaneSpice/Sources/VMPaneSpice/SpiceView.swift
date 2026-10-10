import AppKit
@preconcurrency import CocoaSpice
import MetalKit
import VMPaneCore
import VMPaneQEMU

/// The Metal view of the guest display; turns keyboard and mouse events into SPICE input (PC scancodes,
/// absolute pointer in guest pixels).
final class SpiceView: MTKView {
    var input: CSInput?
    /// The guest display size and the points-to-guest-pixels factor, set by `SpiceDisplay`.
    var guestSize: CGSize = .zero
    var guestScale: CGFloat = 1
    var onResize: (() -> Void)?
    private var buttons: CSInputButton = []
    private var tracking: NSTrackingArea?

    override var acceptsFirstResponder: Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        onResize?()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        onResize?()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    // MARK: Keyboard

    /// Auto-repeat arrives as more presses, which is what a PC keyboard sends too.
    override func keyDown(with event: NSEvent) { key(event, pressed: true) }

    override func keyUp(with event: NSEvent) { key(event, pressed: false) }

    /// Modifier keys only report a flags change: pressed if their flag is now set.
    override func flagsChanged(with event: NSEvent) {
        let flag: NSEvent.ModifierFlags? =
            switch event.keyCode {
            case 56, 60: .shift
            case 59, 62: .control
            case 58, 61: .option
            case 55, 54: .command
            case 57: .capsLock
            default: nil
            }
        guard let flag else { return }
        if flag == .capsLock {  // one event per toggle: a full press
            key(event, pressed: true)
            key(event, pressed: false)
        } else {
            key(event, pressed: event.modifierFlags.contains(flag))
        }
    }

    private func key(_ event: NSEvent, pressed: Bool) {
        guard let input else { return }
        if KeyNames.hidUsage(forMacKeyCode: event.keyCode) == 0x48 {  // Pause has its own sequence
            input.sendPause(pressed ? .press : .release)
            return
        }
        guard let scancode = SpiceKeyMap.scancode(forMacKeyCode: event.keyCode) else { return }
        input.send(pressed ? .press : .release, code: Int32(scancode))
    }

    override func resignFirstResponder() -> Bool {
        input?.releaseKeys()  // no key stays down in the guest when focus leaves
        return super.resignFirstResponder()
    }

    // MARK: Mouse

    override func mouseMoved(with event: NSEvent) { pointer(event) }
    override func mouseDragged(with event: NSEvent) { pointer(event) }
    override func rightMouseDragged(with event: NSEvent) { pointer(event) }
    override func otherMouseDragged(with event: NSEvent) { pointer(event) }
    override func mouseDown(with event: NSEvent) { button(.left, event, pressed: true) }
    override func mouseUp(with event: NSEvent) { button(.left, event, pressed: false) }
    override func rightMouseDown(with event: NSEvent) { button(.right, event, pressed: true) }
    override func rightMouseUp(with event: NSEvent) { button(.right, event, pressed: false) }
    override func otherMouseDown(with event: NSEvent) { button(.middle, event, pressed: true) }
    override func otherMouseUp(with event: NSEvent) { button(.middle, event, pressed: false) }

    override func scrollWheel(with event: NSEvent) {
        guard let input, event.scrollingDeltaY != 0 else { return }
        input.sendMouseScroll(.smooth, buttonMask: buttons, dy: -event.scrollingDeltaY / (event.hasPreciseScrollingDeltas ? 10 : 1))
    }

    private func button(_ button: CSInputButton, _ event: NSEvent, pressed: Bool) {
        pointer(event)
        if pressed { buttons.insert(button) } else { buttons.remove(button) }
        input?.sendMouseButton(button, mask: buttons, pressed: pressed)
    }

    /// The pointer in guest pixels (the display is drawn scaled and centred in the view).
    private func pointer(_ event: NSEvent) {
        guard let input, guestSize.width > 0, guestScale > 0 else { return }
        let local = convert(event.locationInWindow, from: nil)
        let drawn = CGSize(width: guestSize.width * guestScale, height: guestSize.height * guestScale)
        let originX = (bounds.width - drawn.width) / 2, originY = (bounds.height - drawn.height) / 2
        let x = (local.x - originX) / guestScale, y = (bounds.height - local.y - originY) / guestScale
        guard x >= 0, y >= 0, x < guestSize.width, y < guestSize.height else { return }
        input.sendMousePosition(buttons, absolutePoint: CGPoint(x: x, y: y))
    }
}
