import CoreGraphics
import Foundation

/// Where a VM's display can be read: the helper app's display client (a QEMU VM's SPICE session, in memory) or
/// the backend.
public protocol GuestDisplaySource: Sendable {
    /// The display reduced for input verification (`ScreenDiff`); nil without one.
    func grayFrame() async -> GrayFrame?
    /// The display at full resolution, a copy the caller owns (screenshots, text recognition); nil without one.
    func displayImage() async -> CGImage?
}

/// A small grayscale copy of a guest display: what input verification compares (`ScreenDiff`).
public struct GrayFrame: Sendable, Equatable {
    public let width: Int
    public let height: Int
    /// One byte per pixel, rows top to bottom.
    public let pixels: [UInt8]
    /// Guest pixels per frame pixel.
    public let scale: Double

    /// The longest edge frames are reduced to: enough that a typed word still covers whole tiles at 1080p (a
    /// 160-pixel frame shrinks it below a pixel), small enough to diff in well under a millisecond.
    public static let maxEdge = 640

    public init(width: Int, height: Int, pixels: [UInt8], scale: Double = 1) {
        precondition(width >= 0 && height >= 0 && pixels.count == width * height, "a frame has one byte per pixel")
        self.width = width
        self.height = height
        self.pixels = pixels
        self.scale = scale
    }

    /// `image` reduced to fit `maxEdge` (area-averaged, so thin lines fade instead of vanishing or staying sharp).
    public init?(_ image: CGImage, maxEdge: Int = GrayFrame.maxEdge) {
        let scale = ScreenshotEncoder.scale(width: image.width, height: image.height, maxEdge: maxEdge)
        let width = max(1, Int(Double(image.width) / scale)), height = max(1, Int(Double(image.height) / scale))
        var pixels = [UInt8](repeating: 0, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard
                let context = CGContext(
                    data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                    space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        self.init(width: width, height: height, pixels: pixels, scale: Double(image.width) / Double(width))
    }
}

/// What changed between two frames.
public struct ScreenChange: Sendable, Equatable {
    /// A rectangle in guest pixels.
    public struct Box: Sendable, Equatable {
        public var x: Int
        public var y: Int
        public var width: Int
        public var height: Int

        public init(x: Int, y: Int, width: Int, height: Int) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }
    }

    public let changed: Bool
    /// The share of the screen in changed tiles (0…1), and how many tiles that is.
    public let ratio: Double
    public let tiles: Int
    /// Around every changed tile, in guest pixels; nil when unchanged.
    public let box: Box?

    public init(changed: Bool, ratio: Double, tiles: Int = 0, box: Box?) {
        self.changed = changed
        self.ratio = ratio
        self.tiles = tiles
        self.box = box
    }
}

/// Whether input changed the screen. The frames are cut into 16×16 tiles; a tile changed when its pixels differ by
/// more than `tileThreshold` on average, and the screen changed when at least `minTiles` did. Measured on a 1080p
/// desktop (`ScreenDiffTests`): a blinking 1–2 px caret peaks at 1.6–2.5 and a clock's minute ticking over at
/// 1.8–2.4, one typed character at 5.7 and a word at 13; menus and dialogs mark many tiles.
public enum ScreenDiff {
    public static let tile = 16
    /// Mean absolute difference (of 255) that marks a tile.
    public static let tileThreshold = 3.5
    public static let minTiles = 1

    public static func compare(_ before: GrayFrame, _ after: GrayFrame) -> ScreenChange {
        guard before.width == after.width, before.height == after.height, before.pixels.count == after.pixels.count else {
            // The resolution changed: all of it did.
            let box = ScreenChange.Box(
                x: 0, y: 0, width: Int((Double(after.width) * after.scale).rounded()),
                height: Int((Double(after.height) * after.scale).rounded()))
            return ScreenChange(
                changed: true, ratio: 1, tiles: ((after.width + tile - 1) / tile) * ((after.height + tile - 1) / tile), box: box)
        }
        let width = after.width, height = after.height
        guard width > 0, height > 0 else { return ScreenChange(changed: false, ratio: 0, box: nil) }
        let columns = (width + tile - 1) / tile, rows = (height + tile - 1) / tile
        var marked = 0, markedArea = 0
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        before.pixels.withUnsafeBufferPointer { old in
            after.pixels.withUnsafeBufferPointer { new in
                for row in 0..<rows {
                    let top = row * tile, bottom = min(top + tile, height)
                    for column in 0..<columns {
                        let left = column * tile, right = min(left + tile, width)
                        var sum = 0
                        for y in top..<bottom {
                            let base = y * width
                            for x in left..<right { sum += abs(Int(old[base + x]) - Int(new[base + x])) }
                        }
                        let area = (bottom - top) * (right - left)
                        // Over a whole tile's area even at the frame's edge: a sliver of a tile (a 1-pixel last row)
                        // would otherwise magnify a few changed pixels (a console's cursor line) many times.
                        guard Double(sum) > tileThreshold * Double(tile * tile) else { continue }
                        marked += 1
                        markedArea += area
                        minX = min(minX, left)
                        minY = min(minY, top)
                        maxX = max(maxX, right)
                        maxY = max(maxY, bottom)
                    }
                }
            }
        }
        let ratio = Double(markedArea) / Double(width * height)
        guard marked >= minTiles else { return ScreenChange(changed: false, ratio: ratio, tiles: marked, box: nil) }
        let scale = after.scale
        let box = ScreenChange.Box(
            x: Int((Double(minX) * scale).rounded()), y: Int((Double(minY) * scale).rounded()),
            width: Int((Double(maxX - minX) * scale).rounded()), height: Int((Double(maxY - minY) * scale).rounded()))
        return ScreenChange(changed: true, ratio: ratio, tiles: marked, box: box)
    }
}
