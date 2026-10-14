import AppKit
import IOSurface
import QuartzCore

/// Shows a Linux guest's boot screen at a readable size. Virtualization's EFI firmware starts the screen in its
/// largest mode, 8192 × 4320, whatever the VM's display size, and boot loaders keep it (GRUB, until its menu times
/// out; then Linux, until its GPU driver sets the VM's size). Drawn whole in the window, that text is a few pixels
/// tall. The firmware has nothing to change it with (no setup screen, no resolution variable), so while the screen
/// is that large the window shows its top-left corner, where the firmware, GRUB and Linux write, at one guest pixel
/// per point: the size of a `.standard` display's console.
///
/// An overlay drawn from the guest framebuffer's IOSurface (the one capture reads), copying only the corner shown:
/// the VM's view keeps its input and its own drawing underneath.
@MainActor
final class VZFirmwareZoom {
    /// The guest pixels to show in a view of `view` points (from the screen's top-left corner), or nil to show the
    /// screen whole: only a framebuffer of the firmware's size, at least 3 guest pixels per point across, which no
    /// display VMPane configures reaches (`.retina` is 2, `.standard` 1).
    nonisolated static func region(framebuffer: CGSize, view: CGSize) -> CGSize? {
        guard view.width >= 1, view.height >= 1, framebuffer.width >= 4096, framebuffer.width >= 3 * view.width else {
            return nil
        }
        return CGSize(
            width: min(framebuffer.width, view.width.rounded(.down)), height: min(framebuffer.height, view.height.rounded(.down)))
    }

    private let overlay = PassThroughView()
    private weak var display: NSView?
    private let surface: () -> IOSurfaceRef?
    private var timer: Timer?

    init(over display: NSView, surface: @escaping () -> IOSurfaceRef?) {
        self.display = display
        self.surface = surface
        overlay.wantsLayer = true
        overlay.layer?.backgroundColor = NSColor.black.cgColor
        overlay.layer?.contentsGravity = .resize
        // Guest pixels as squares, not smoothed: firmware text is a bitmap font.
        overlay.layer?.magnificationFilter = .nearest
        overlay.isHidden = true
        overlay.setAccessibilityElement(false)
        overlay.frame = display.bounds
        overlay.autoresizingMask = [.width, .height]
        display.addSubview(overlay)
        schedule(every: 0.5)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        overlay.removeFromSuperview()
    }

    /// Checks twice a second; while zoomed, refreshes often enough to follow GRUB's menu and typing.
    private func schedule(every interval: TimeInterval) {
        guard timer?.timeInterval != interval else { return }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        guard let display, display.window?.alphaValue ?? 0 > 0, let surface = surface(),
            let region = Self.region(
                framebuffer: CGSize(width: IOSurfaceGetWidth(surface), height: IOSurfaceGetHeight(surface)),
                view: display.bounds.size),
            let image = Self.corner(of: surface, size: region)
        else {
            if !overlay.isHidden {
                overlay.isHidden = true
                overlay.layer?.contents = nil
            }
            schedule(every: 0.5)
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        overlay.layer?.contents = image
        overlay.isHidden = false
        CATransaction.commit()
        schedule(every: 1.0 / 15)
    }

    /// The framebuffer's top-left `size` pixels as an image of their own.
    private static func corner(of surface: IOSurfaceRef, size: CGSize) -> CGImage? {
        let width = Int(size.width), height = Int(size.height), rowBytes = width * 4
        IOSurfaceLock(surface, .readOnly, nil)
        defer { IOSurfaceUnlock(surface, .readOnly, nil) }
        let source = IOSurfaceGetBaseAddress(surface), sourceRowBytes = IOSurfaceGetBytesPerRow(surface)
        guard sourceRowBytes >= rowBytes, IOSurfaceGetHeight(surface) >= height else { return nil }
        var pixels = Data(count: rowBytes * height)
        pixels.withUnsafeMutableBytes { target in
            guard let base = target.baseAddress else { return }
            for row in 0..<height {
                base.advanced(by: row * rowBytes).copyMemory(from: source.advanced(by: row * sourceRowBytes), byteCount: rowBytes)
            }
        }
        guard let provider = CGDataProvider(data: pixels as CFData) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: rowBytes,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

/// Drawn only: clicks reach the VM's view below, which takes the keyboard focus.
private final class PassThroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
