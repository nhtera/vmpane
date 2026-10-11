import AppKit
import VMPaneCore

/// The helper's Dock tile: the VM's own icon (`icon.png` in the bundle) or its system's symbol on a rounded
/// tile, with a dot for its state, so three running VMs show three distinct tiles.
@MainActor
public enum DockIcon {
    public static let size = NSSize(width: 512, height: 512)

    public static func image(os: GuestOS?, state: VMRunState, custom: NSImage? = nil) -> NSImage {
        NSImage(size: size, flipped: false) { rect in
            let tile = rect.insetBy(dx: 40, dy: 40)
            let path = NSBezierPath(roundedRect: tile, xRadius: 90, yRadius: 90)
            if let custom {
                path.addClip()
                custom.draw(in: tile)
            } else {
                Self.background(os).setFill()
                path.fill()
                let configuration = NSImage.SymbolConfiguration(pointSize: 220, weight: .regular)
                    .applying(.init(paletteColors: [.white]))
                if let symbol = NSImage(systemSymbolName: Self.symbol(os), accessibilityDescription: nil)?.withSymbolConfiguration(
                    configuration)
                {
                    let origin = NSPoint(x: tile.midX - symbol.size.width / 2, y: tile.midY - symbol.size.height / 2)
                    symbol.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1)
                }
            }
            let dot = NSRect(x: tile.maxX - 120, y: tile.minY + 10, width: 110, height: 110)
            NSColor.white.setFill()
            NSBezierPath(ovalIn: dot).fill()
            Self.stateColor(state).setFill()
            NSBezierPath(ovalIn: dot.insetBy(dx: 14, dy: 14)).fill()
            return true
        }
    }

    /// The Dock badge: the state when the VM is not simply running or stopped.
    public static func badge(_ state: VMRunState) -> String? {
        switch state {
        case .paused: "Paused"
        case .suspending: "Saving"
        case .starting: "Starting"
        case .error: "Error"
        default: nil
        }
    }

    static func symbol(_ os: GuestOS?) -> String { OSBadge.symbol(os) }

    static func background(_ os: GuestOS?) -> NSColor {
        switch os {
        case .macos?: NSColor(calibratedRed: 0.20, green: 0.22, blue: 0.27, alpha: 1)
        case .linux?: NSColor(calibratedRed: 0.86, green: 0.36, blue: 0.13, alpha: 1)
        case .windows?: NSColor(calibratedRed: 0.0, green: 0.47, blue: 0.84, alpha: 1)
        case nil: .gray
        }
    }

    static func stateColor(_ state: VMRunState) -> NSColor {
        switch state {
        case .running: .systemGreen
        case .paused, .suspending, .starting, .stopping: .systemOrange
        case .error: .systemRed
        case .stopped: .systemGray
        }
    }
}
