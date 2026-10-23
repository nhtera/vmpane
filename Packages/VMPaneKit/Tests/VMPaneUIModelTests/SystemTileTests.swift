import Foundation
import Testing

@testable import VMPaneUI

/// White glyphs on every brand tile keep at least 3:1 (large graphics, WCAG 1.4.11) against the tile's lighter stop.
@Test func whiteGlyphsStandOutOnEveryTile() throws {
    func luminance(_ rgb: UInt32) -> Double {
        func channel(_ value: UInt32) -> Double {
            let linear = Double(value & 0xFF) / 255
            return linear <= 0.03928 ? linear / 12.92 : pow((linear + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(rgb >> 16) + 0.7152 * channel(rgb >> 8) + 0.0722 * channel(rgb)
    }
    let systems: [SystemTile.System] = [.macos, .ubuntu, .debian, .fedora, .linux, .windows]
    for system in systems {
        let top = try #require(system.stops).top
        let contrast = 1.05 / (luminance(top) + 0.05)
        #expect(contrast >= 3, "\(system): \(contrast)")
    }
    #expect(SystemTile.System.installer.stops == nil)
}

/// A VM's tile follows its system, and a cloud image's distribution when the VM knows it.
@Test func aVMsTileFollowsItsSystem() {
    #expect(SystemTile.System(.linux, distro: "fedora") == .fedora && SystemTile.System(.linux) == .linux)
    #expect(SystemTile.System(.windows) == .windows && SystemTile.System(nil) == .installer)
    #expect(SystemTile.System(.debian) == .debian)
}
