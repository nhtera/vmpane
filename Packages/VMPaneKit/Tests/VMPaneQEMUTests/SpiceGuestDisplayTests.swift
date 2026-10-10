import CoreGraphics
import Testing
import VMPaneCore

@testable import VMPaneQEMU

@Test func guestResolutionFollowsTheWindowInPixelsOrPoints() {
    let window = CGSize(width: 1201, height: 801)
    #expect(SpiceGuestDisplay.resolution(forContent: window, backingScale: 2, scaling: .retina) == CGSize(width: 2402, height: 1602))
    #expect(SpiceGuestDisplay.resolution(forContent: window, backingScale: 2, scaling: .standard) == CGSize(width: 1200, height: 800))
    // Never below what Windows supports, whatever the window.
    let tiny = CGSize(width: 300, height: 200)
    #expect(SpiceGuestDisplay.resolution(forContent: tiny, backingScale: 1, scaling: .retina) == CGSize(width: 800, height: 600))
}

@Test func clipboardModesAllowTheirDirectionsOnly() {
    #expect(ClipboardConfig.Mode.both.sendsToGuest && ClipboardConfig.Mode.both.receivesFromGuest)
    #expect(ClipboardConfig.Mode.hostToGuest.sendsToGuest && !ClipboardConfig.Mode.hostToGuest.receivesFromGuest)
    #expect(!ClipboardConfig.Mode.guestToHost.sendsToGuest && ClipboardConfig.Mode.guestToHost.receivesFromGuest)
    #expect(!ClipboardConfig.Mode.off.sendsToGuest && !ClipboardConfig.Mode.off.receivesFromGuest)
}
