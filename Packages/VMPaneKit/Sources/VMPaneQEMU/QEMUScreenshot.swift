import CoreGraphics
import Foundation
import VMPaneCore

public enum QEMUScreenshotError: Error, Equatable, Sendable {
    /// The file QEMU wrote is not a PPM this decoder accepts (or exceeds the size cap).
    case invalidImage(String)
}

/// QMP `screendump` writes PPM (this QEMU has no libpng). The file comes from QEMU, so it is untrusted:
/// strict P6 parsing, a dimension cap, and the pixel data must match the header exactly.
enum QEMUScreenshot {
    static let maxDimension = 8192

    struct Pixels: Equatable {
        let width: Int
        let height: Int
        /// RGB, 3 bytes per pixel, rows top to bottom.
        let rgb: Data
    }

    static func decodePPM(_ data: Data) throws -> Pixels {
        var index = data.startIndex
        func token() throws -> String {
            while index < data.endIndex, isSpace(data[index]) { index += 1 }
            let start = index
            while index < data.endIndex, !isSpace(data[index]), index - start < 16 { index += 1 }
            guard index > start, index < data.endIndex, isSpace(data[index]) else { throw QEMUScreenshotError.invalidImage("header") }
            guard let text = String(bytes: data[start..<index], encoding: .ascii) else { throw QEMUScreenshotError.invalidImage("header") }
            return text
        }
        guard try token() == "P6" else { throw QEMUScreenshotError.invalidImage("not P6") }
        guard let width = Int(try token()), let height = Int(try token()), let maxValue = Int(try token()) else {
            throw QEMUScreenshotError.invalidImage("header")
        }
        guard (1...maxDimension).contains(width), (1...maxDimension).contains(height) else {
            throw QEMUScreenshotError.invalidImage("size \(width)x\(height)")
        }
        guard maxValue == 255 else { throw QEMUScreenshotError.invalidImage("max value \(maxValue)") }
        index += 1  // exactly one whitespace byte before the pixels
        let pixels = data[index...]
        guard pixels.count == width * height * 3 else { throw QEMUScreenshotError.invalidImage("pixel data length") }
        return Pixels(width: width, height: height, rgb: Data(pixels))
    }

    static func image(_ pixels: Pixels) -> CGImage? {
        guard let provider = CGDataProvider(data: pixels.rgb as CFData) else { return nil }
        return CGImage(
            width: pixels.width, height: pixels.height, bitsPerComponent: 8, bitsPerPixel: 24, bytesPerRow: pixels.width * 3,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent)
    }

    /// Whether the display shows anything (a booting or sleeping guest is black).
    static func isBlack(_ pixels: Pixels) -> Bool {
        stride(from: 0, to: pixels.rgb.count - 2, by: 3 * 97).allSatisfy { offset in
            let base = pixels.rgb.startIndex + offset
            return Int(pixels.rgb[base]) + Int(pixels.rgb[base + 1]) + Int(pixels.rgb[base + 2]) <= 30
        }
    }

    private static func isSpace(_ byte: UInt8) -> Bool { byte == 0x20 || byte == 0x0A || byte == 0x0D || byte == 0x09 }
}
