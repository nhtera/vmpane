import CoreGraphics
import Testing

@testable import VMPaneVZ

@Test func backendName() { #expect(VZBackendInfo.name == "vz") }

/// The firmware's 8192 × 4320 boot screen shows its top-left corner at one guest pixel per point; screens VMPane
/// configures (one or two guest pixels per point) show whole.
@Test func onlyTheFirmwaresBootScreenIsZoomed() {
    func region(_ framebuffer: (CGFloat, CGFloat), _ view: (CGFloat, CGFloat)) -> CGSize? {
        VZFirmwareZoom.region(
            framebuffer: CGSize(width: framebuffer.0, height: framebuffer.1), view: CGSize(width: view.0, height: view.1))
    }
    #expect(region((8192, 4320), (960, 600)) == CGSize(width: 960, height: 600))
    #expect(region((8192, 4320), (1512.5, 900)) == CGSize(width: 1512, height: 900), "whole guest pixels")
    #expect(region((960, 600), (960, 600)) == nil, "standard")
    #expect(region((1920, 1200), (960, 600)) == nil, "retina")
    #expect(region((6016, 3384), (3008, 1692)) == nil, "6K retina")
    #expect(region((8192, 4320), (3008, 1692)) == nil, "large enough to read")
    #expect(region((8192, 4320), (0, 0)) == nil)
}
