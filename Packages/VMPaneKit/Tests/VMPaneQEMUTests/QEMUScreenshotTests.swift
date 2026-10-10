import Foundation
import ImageIO
import Testing
import VMPaneCore

@testable import VMPaneQEMU

private func ppm(_ header: String, pixels: Int, value: UInt8 = 0x80) -> Data {
    Data(header.utf8) + Data(repeating: value, count: pixels * 3)
}

@Test func decodesQEMUsPPM() throws {
    let pixels = try QEMUScreenshot.decodePPM(ppm("P6\n800 600\n255\n", pixels: 800 * 600))
    #expect(pixels.width == 800 && pixels.height == 600 && pixels.rgb.count == 1_440_000)
    #expect(!QEMUScreenshot.isBlack(pixels))
    #expect(QEMUScreenshot.isBlack(try QEMUScreenshot.decodePPM(ppm("P6\n4 4\n255\n", pixels: 16, value: 0))))

    let image = try #require(QEMUScreenshot.image(pixels))
    let shot = try #require(ScreenshotEncoder.png(image, maxEdge: 400))
    #expect(shot.width == 400 && shot.height == 300)
    let source = try #require(CGImageSourceCreateWithData(shot.png as CFData, nil))
    #expect(CGImageSourceGetCount(source) == 1)
}

@Test func rejectsMalformedOrOversizedPPM() {
    let bad: [Data] = [
        ppm("P3\n2 2\n255\n", pixels: 4),  // ASCII PPM
        ppm("P6\n2 2\n65535\n", pixels: 8),  // 16-bit
        ppm("P6\n2 2\n255\n", pixels: 3),  // short
        ppm("P6\n2 2\n255\n", pixels: 5),  // trailing data
        ppm("P6\n0 2\n255\n", pixels: 0),
        ppm("P6\n9000 1\n255\n", pixels: 9000),  // over the cap
        ppm("P6\n-2 2\n255\n", pixels: 4),
        ppm("P6\n# comment\n2 2\n255\n", pixels: 4),
        Data("P6".utf8), Data(),
    ]
    for data in bad {
        #expect(throws: QEMUScreenshotError.self) { try QEMUScreenshot.decodePPM(data) }
    }
}
