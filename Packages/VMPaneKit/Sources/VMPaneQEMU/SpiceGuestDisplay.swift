import CoreGraphics
import VMPaneCore

/// The decisions of the SPICE window's guest integration, kept here to be testable (VMPaneSpice links the SPICE
/// client libraries and has no test target).
public enum SpiceGuestDisplay {
    /// Windows' smallest supported resolution.
    public static let minimumSize = CGSize(width: 800, height: 600)
    /// Window resizes are sent to the guest agent once the window has kept its size this long.
    public static let resizeDebounce = Duration.milliseconds(300)

    /// The guest resolution for a window content size (points): pixels with retina scaling, points with standard
    /// scaling; even (some drivers want it) and at least `minimumSize`.
    public static func resolution(forContent size: CGSize, backingScale: CGFloat, scaling: DisplayConfig.Scaling) -> CGSize {
        scaling.guestResolution(forContent: size, backingScale: backingScale, minimum: minimumSize)
    }
}

extension ClipboardConfig.Mode {
    /// The Mac's clipboard may be offered to the guest.
    public var sendsToGuest: Bool { self == .both || self == .hostToGuest }
    /// The guest may set the Mac's clipboard.
    public var receivesFromGuest: Bool { self == .both || self == .guestToHost }
}
