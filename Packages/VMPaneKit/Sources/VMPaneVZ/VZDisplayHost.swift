import AppKit
import IOSurface
import QuartzCore
import UniformTypeIdentifiers
import VMPaneCore
import Virtualization

/// The VM's view and window. Visible when the user opens it; otherwise kept on screen at alpha 0, so
/// capture and input keep working headless. Main actor only; it only sets `virtualMachine` (ADR 0003).
///
/// Capture (C2) reads the IOSurface behind the view's layers: undocumented view internals, checked by a
/// self-test at start (fallback: the guest agent, Phase 07). Input (I1) sends synthesized `NSEvent`s to
/// the view; no Accessibility or Screen Recording permission is involved.
@MainActor
public final class VZDisplayHost {
    public let window: NSWindow
    public let view: VZVirtualMachineView

    public init(box: VMBox, title: String, guestSize: NSSize) {
        view = VZVirtualMachineView(frame: NSRect(origin: .zero, size: guestSize))
        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: NSSize(width: guestSize.width / 2, height: guestSize.height / 2)),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = title
        window.contentView = view
        window.contentAspectRatio = guestSize
        window.isReleasedWhenClosed = false
        window.center()
        view.virtualMachine = box.virtualMachine
        view.capturesSystemKeys = true
        view.automaticallyReconfiguresDisplay = true
        hide()
        window.orderFront(nil)
    }

    public var isVisible: Bool { window.alphaValue > 0 }

    public func show() {
        window.alphaValue = 1
        window.ignoresMouseEvents = false
        window.isExcludedFromWindowsMenu = false
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        NSApp.activate()
    }

    /// Invisible but on screen: the guest keeps rendering, so capture and input still work.
    public func hide() {
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.isExcludedFromWindowsMenu = true
    }

    /// Releases the VM: AppKit keeps every unclosed window, and a window's view keeps its VM (and the VM's
    /// files) alive, so a later restore in this process would fail with "permission denied".
    public func close() {
        view.virtualMachine = nil
        window.orderOut(nil)
        window.close()
    }

    /// Whether the guest display follows the window size; true when applied.
    public func setAutoResize(_ value: Bool) -> Bool {
        view.automaticallyReconfiguresDisplay = value
        return true
    }

    // MARK: - Capture (C2)

    public struct Capture: Sendable {
        public let png: Data
        public let width: Int
        public let height: Int
        /// Guest pixels per captured pixel (≥ 1 when scaled down to `maxEdge`).
        public let scale: Double
    }

    /// The guest framebuffer as PNG, longest edge at most `maxEdge`.
    public func capture(maxEdge: Int) -> Capture? {
        guard let image = framebuffer() else { return nil }
        let longest = max(image.width, image.height)
        let scale = longest > maxEdge && maxEdge > 0 ? Double(longest) / Double(maxEdge) : 1
        let width = Int(Double(image.width) / scale), height = Int(Double(image.height) / scale)
        guard
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaled = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, scaled, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return Capture(png: data as Data, width: width, height: height, scale: scale)
    }

    /// Start-up self-test: a framebuffer exists and is not uniformly black.
    public func selfTest() -> Bool {
        guard let image = framebuffer(), let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return false }
        let length = CFDataGetLength(data)
        var lit = 0
        for offset in stride(from: 0, to: length - 3, by: 4 * 97)
        where Int(bytes[offset]) + Int(bytes[offset + 1]) + Int(bytes[offset + 2]) > 30 {
            lit += 1
        }
        return lit > 0
    }

    private func framebuffer() -> CGImage? {
        guard let root = view.layer, let surface = Self.findSurface(root) else { return nil }
        IOSurfaceLock(surface, .readOnly, nil)
        defer { IOSurfaceUnlock(surface, .readOnly, nil) }
        let width = IOSurfaceGetWidth(surface), height = IOSurfaceGetHeight(surface), rowBytes = IOSurfaceGetBytesPerRow(surface)
        guard width > 0, height > 0 else { return nil }
        let data = Data(bytes: IOSurfaceGetBaseAddress(surface), count: rowBytes * height)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: rowBytes,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    private static func findSurface(_ layer: CALayer) -> IOSurfaceRef? {
        if let contents = layer.contents, CFGetTypeID(contents as CFTypeRef) == IOSurfaceGetTypeID() {
            // The type ID was checked on the line above.
            return (contents as! IOSurfaceRef)  // swiftlint:disable:this force_cast
        }
        for sublayer in layer.sublayers ?? [] {
            if let surface = findSurface(sublayer) { return surface }
        }
        return nil
    }

    // MARK: - Input (I1)

    public enum InputError: Error, Equatable, Sendable {
        case unmappedCharacter(Character)
        case unmappedKey(UInt16)
    }

    public func send(_ input: InputEvent) throws {
        switch input {
        case .text(let text):
            for character in text {
                guard let stroke = VZKeyMap.stroke(for: character) else { throw InputError.unmappedCharacter(character) }
                press(keyCode: stroke.keyCode, characters: String(character == "\n" ? "\r" : character), shift: stroke.shift)
            }
        case .key(let usage, let down):
            guard let code = VZKeyMap.keyCode(forHIDUsage: usage) else { throw InputError.unmappedKey(usage) }
            keyEvent(down ? .keyDown : .keyUp, keyCode: code, characters: "", flags: [])
        case .pointer(let x, let y, let buttons):
            pointer(x: x, y: y, buttons: buttons)
        case .scroll(let dx, let dy):
            if let cgEvent = CGEvent(
                scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: Int32(dy), wheel2: Int32(dx), wheel3: 0),
                let event = NSEvent(cgEvent: cgEvent)
            {
                view.scrollWheel(with: event)
            }
        }
    }

    private var pressedButtons = 0

    /// What a real left-Shift press sets: the device-independent Shift flag plus the device-dependent
    /// left-Shift bit (NX_DEVICELSHIFTKEYMASK) and NX_NONCOALSESCEDMASK. The view reads the device bits.
    static let leftShiftDown = NSEvent.ModifierFlags(rawValue: 0x0002_0102)
    static let noModifiers = NSEvent.ModifierFlags(rawValue: 0x0000_0100)

    private func press(keyCode: UInt16, characters: String, shift: Bool) {
        let held = shift ? Self.leftShiftDown : Self.noModifiers
        if shift { flags(Self.leftShiftDown) }
        keyEvent(.keyDown, keyCode: keyCode, characters: characters, flags: held)
        keyEvent(.keyUp, keyCode: keyCode, characters: characters, flags: held)
        if shift { flags(Self.noModifiers) }
    }

    private func flags(_ flags: NSEvent.ModifierFlags) {
        if let event = NSEvent.keyEvent(
            with: .flagsChanged, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false,
            keyCode: VZKeyMap.shiftKeyCode)
        {
            view.flagsChanged(with: event)
        }
    }

    private func keyEvent(_ type: NSEvent.EventType, keyCode: UInt16, characters: String, flags: NSEvent.ModifierFlags) {
        guard
            let event = NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: keyCode)
        else { return }
        if type == .keyDown {
            view.keyDown(with: event)
        } else {
            view.keyUp(with: event)
        }
    }

    /// Guest display coordinates (origin top-left, guest pixels) → view coordinates.
    private func pointer(x: Double, y: Double, buttons: Int) {
        let bounds = view.bounds
        guard let surface = view.layer.flatMap(Self.findSurface) else { return }
        let guestWidth = Double(IOSurfaceGetWidth(surface)), guestHeight = Double(IOSurfaceGetHeight(surface))
        let point = NSPoint(x: x / guestWidth * bounds.width, y: bounds.height - y / guestHeight * bounds.height)
        let location = view.convert(point, to: nil)
        // Bit 0 left, bit 1 right, bit 2 middle (other). A move first, then each button that changed.
        let previous = pressedButtons
        let move: (NSEvent.EventType, Int) =
            previous & 1 != 0
            ? (.leftMouseDragged, 0)
            : previous & 2 != 0 ? (.rightMouseDragged, 1) : previous & 4 != 0 ? (.otherMouseDragged, 2) : (.mouseMoved, 0)
        send(move.0, at: location, button: move.1, down: previous != 0)
        for bit in 0..<3 where (previous ^ buttons) & (1 << bit) != 0 {
            let down = buttons & (1 << bit) != 0
            let type: NSEvent.EventType =
                switch bit {
                case 0: down ? .leftMouseDown : .leftMouseUp
                case 1: down ? .rightMouseDown : .rightMouseUp
                default: down ? .otherMouseDown : .otherMouseUp
                }
            send(type, at: location, button: bit, down: down)
        }
        pressedButtons = buttons
    }

    private func send(_ type: NSEvent.EventType, at location: NSPoint, button: Int, down: Bool) {
        guard
            let cgEvent = NSEvent.mouseEvent(
                with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: down ? 1 : 0)?
                .cgEvent
        else { return }
        cgEvent.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button))
        guard let event = NSEvent(cgEvent: cgEvent) else { return }
        switch type {
        case .leftMouseDown: view.mouseDown(with: event)
        case .leftMouseUp: view.mouseUp(with: event)
        case .rightMouseDown: view.rightMouseDown(with: event)
        case .rightMouseUp: view.rightMouseUp(with: event)
        case .otherMouseDown: view.otherMouseDown(with: event)
        case .otherMouseUp: view.otherMouseUp(with: event)
        case .leftMouseDragged: view.mouseDragged(with: event)
        case .rightMouseDragged: view.rightMouseDragged(with: event)
        case .otherMouseDragged: view.otherMouseDragged(with: event)
        default: view.mouseMoved(with: event)
        }
    }
}
