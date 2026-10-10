import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Guest display captures as PNG, downscaled so the longest edge is at most `maxEdge` (VZ framebuffer,
/// QEMU `screendump`).
public enum ScreenshotEncoder {
    /// The scale factor (≥ 1) that fits `width`×`height` into `maxEdge` (0 = no limit).
    public static func scale(width: Int, height: Int, maxEdge: Int) -> Double {
        let longest = max(width, height)
        return longest > maxEdge && maxEdge > 0 ? Double(longest) / Double(maxEdge) : 1
    }

    public static func png(_ image: CGImage, maxEdge: Int) -> Screenshot? {
        let scale = scale(width: image.width, height: image.height, maxEdge: maxEdge)
        let width = max(1, Int(Double(image.width) / scale)), height = max(1, Int(Double(image.height) / scale))
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
        return Screenshot(png: data as Data, width: width, height: height)
    }
}
