import CoreGraphics
import CoreText
import Foundation
import Testing

@testable import VMPaneCore

/// A 1080p desktop drawn the way guests draw theirs: a light window with text, a dark taskbar with a clock.
private struct Desktop {
    var width = 1920
    var height = 1080
    var caret = false
    var caretWidth = 1
    var clock = "10:41"
    var typed = ""
    var dialog: CGRect?

    func image() -> CGImage? {
        guard
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        // CoreGraphics has its origin at the bottom left; the rectangles here are top-left based like the guest's.
        func fill(_ rect: CGRect, _ gray: CGFloat) {
            context.setFillColor(gray: gray, alpha: 1)
            context.fill(CGRect(x: rect.minX, y: CGFloat(height) - rect.maxY, width: rect.width, height: rect.height))
        }
        func text(_ string: String, at point: CGPoint, size: CGFloat, gray: CGFloat) {
            let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
            let color = CGColor(gray: gray, alpha: 1)
            let attributed = NSAttributedString(
                string: string,
                attributes: [
                    NSAttributedString.Key(kCTFontAttributeName as String): font,
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
                ])
            context.textPosition = CGPoint(x: point.x, y: CGFloat(height) - point.y)
            CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
        }
        fill(CGRect(x: 0, y: 0, width: width, height: height), 0.35)  // wallpaper
        fill(CGRect(x: 200, y: 120, width: 1200, height: 700), 0.97)  // a window
        text("Documents  Downloads  Pictures  Music  Videos", at: CGPoint(x: 240, y: 200), size: 14, gray: 0.1)
        fill(CGRect(x: 240, y: 280, width: 600, height: 28), 1)  // a text field
        text(typed, at: CGPoint(x: 246, y: 300), size: 14, gray: 0.1)
        if caret { fill(CGRect(x: 246 + 8 * typed.count, y: 284, width: caretWidth, height: 20), 0) }
        fill(CGRect(x: 0, y: 1032, width: width, height: 48), 0.12)  // taskbar
        text(clock, at: CGPoint(x: 1840, y: 1062), size: 12, gray: 0.95)
        if let dialog {
            fill(dialog, 0.6)
            fill(dialog.insetBy(dx: 1, dy: 1), 0.94)
            text("Do you want to save the changes?", at: CGPoint(x: dialog.minX + 24, y: dialog.minY + 60), size: 14, gray: 0.1)
            fill(CGRect(x: dialog.maxX - 200, y: dialog.maxY - 60, width: 80, height: 28), 0.2)
        }
        return context.makeImage()
    }

    /// The desktop as a frame (an empty one if it could not be drawn, which the size test catches).
    var frame: GrayFrame { image().flatMap { GrayFrame($0) } ?? GrayFrame(width: 0, height: 0, pixels: []) }
}

@Test func framesAreReducedToTheirMaximumEdge() {
    let frame = Desktop().frame
    #expect(frame.width == GrayFrame.maxEdge && frame.height == 360)
    #expect(frame.scale == 3)
    #expect(frame.pixels.count == frame.width * frame.height)
}

@Test func theSameScreenIsUnchanged() {
    let change = ScreenDiff.compare(Desktop().frame, Desktop().frame)
    #expect(!change.changed && change.ratio == 0 && change.box == nil)
}

@Test func aBlinkingCaretIsUnchanged() {
    #expect(!ScreenDiff.compare(Desktop(typed: "hello").frame, Desktop(caret: true, typed: "hello").frame).changed)
    #expect(!ScreenDiff.compare(Desktop(typed: "hello").frame, Desktop(caret: true, caretWidth: 2, typed: "hello").frame).changed)
}

@Test func aClockTickIsUnchanged() {
    #expect(!ScreenDiff.compare(Desktop(clock: "10:41").frame, Desktop(clock: "10:42").frame).changed)
    #expect(!ScreenDiff.compare(Desktop(clock: "10:49").frame, Desktop(clock: "10:50").frame).changed)
}

@Test func aTypedWordIsAChange() throws {
    let change = ScreenDiff.compare(Desktop(caret: true).frame, Desktop(caret: true, typed: "hello").frame)
    #expect(change.changed)
    let box = try #require(change.box)
    #expect(box.x >= 200 && box.y >= 250 && box.y + box.height <= 340, "around the field")
    #expect(ScreenDiff.compare(Desktop(caret: true).frame, Desktop(caret: true, typed: "ok").frame).changed)
}

@Test func aDialogIsAChangeBoxedAroundIt() throws {
    let dialog = CGRect(x: 760, y: 390, width: 400, height: 300)
    let change = ScreenDiff.compare(Desktop().frame, Desktop(dialog: dialog).frame)
    #expect(change.changed)
    let box = try #require(change.box)
    let found = CGRect(x: box.x, y: box.y, width: box.width, height: box.height)
    let slack = CGFloat(ScreenDiff.tile) * 3  // a tile at the frame's scale
    // Tiles the dialog's low-contrast edge only grazes stay below the threshold.
    #expect(found.insetBy(dx: -slack, dy: -slack).contains(dialog), "covers the dialog")
    #expect(dialog.insetBy(dx: -slack, dy: -slack).contains(found), "and little else")
    #expect(change.ratio > 0.05 && change.ratio < 0.1)
}

@Test func theFramesEdgeIsNoMoreSensitiveThanItsMiddle() {
    // 17 rows: one row of tiles and a sliver of a second; a cursor-sized change in the sliver is no change.
    let before = GrayFrame(width: 64, height: 17, pixels: [UInt8](repeating: 0, count: 64 * 17))
    var pixels = before.pixels
    for x in 0..<3 { pixels[16 * 64 + x] = 200 }  // 600 of the 896 a tile needs; 11 times the 56 a 16×1 sliver did
    #expect(!ScreenDiff.compare(before, GrayFrame(width: 64, height: 17, pixels: pixels)).changed)
}

@Test func aNewResolutionIsAChangeOfEverything() {
    let change = ScreenDiff.compare(Desktop().frame, Desktop(width: 1280, height: 800).frame)
    #expect(change.changed && change.ratio == 1 && change.box == ScreenChange.Box(x: 0, y: 0, width: 1280, height: 800))
}

@Test func diffingIsFast() {
    let before = Desktop().frame, after = Desktop(dialog: CGRect(x: 100, y: 100, width: 800, height: 600)).frame
    let clock = ContinuousClock()
    // The fastest of 20: other tests running alongside slow single runs, not the fastest.
    let fastest = (0..<20).map { _ in clock.measure { _ = ScreenDiff.compare(before, after) } }.min() ?? .seconds(1)
    #if DEBUG
        let budget = Duration.milliseconds(30)  // unoptimized: bounds checks on every pixel
    #else
        let budget = Duration.milliseconds(5)  // Phase 01's target
    #endif
    #expect(fastest < budget, "\(fastest) per pair")
}
