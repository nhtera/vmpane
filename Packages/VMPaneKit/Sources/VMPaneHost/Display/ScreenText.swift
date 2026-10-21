import CoreGraphics
import Foundation
import VMPaneCore
import Vision

/// Text on a guest's screen, recognized on the Mac (Vision) from the full-resolution display: no permission or
/// software in the guest. Boxes are guest pixels, origin top left.
public enum ScreenText {
    public struct Line: Sendable, Equatable {
        public var text: String
        public var confidence: Float
        public var rect: CGRect
    }

    private static let serial = NSLock()

    /// Below this share of `.fast`'s line count, `.accurate` is taken to have skipped a dense screen.
    static let denseShare = 0.8

    /// A region with its longest edge below this is enlarged twice first: small UI text reads better.
    static let enlargeBelow = 800

    /// The lines of text in `image`, or in `region` of it (guest pixels), top to bottom.
    public static func recognize(_ image: CGImage, region: CGRect? = nil) throws -> [Line] {
        // One recognition at a time per process (one helper, one VM): each takes the Neural Engine for up to a
        // second, and readers that pile up would only slow the Mac down.
        serial.lock()
        defer { serial.unlock() }
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let area = (region ?? bounds).integral.intersection(bounds)
        guard !area.isEmpty, var source = area == bounds ? image : image.cropping(to: area) else { return [] }
        var factor = 1.0
        if region != nil, max(source.width, source.height) < enlargeBelow, let larger = enlarged(source) {
            source = larger
            factor = 2
        }
        // `.accurate` reads UI text best but skips much of a dense screen (a 2144×1344 Linux console: 25 of ~80
        // lines, and never the last one at the edge); `.fast` finds them but misreads a console's bitmap font. A
        // dense screen (accurate read under `denseShare` of what fast did: 21–86 of ~155 lines on consoles, 40 of 34
        // on Windows Settings) is read again by accurate in overlapping
        // padded quarters; fast fills in what accurate did not cover.
        let fastLines = try lines(in: source, level: .fast)
        var accurate = try lines(in: source, level: .accurate)
        if Double(accurate.count) < denseShare * Double(fastLines.count) {
            accurate = try quarters(of: source)
        }
        // A fast line stays unless accurate readings cover nearly all of its width (they often cover part of it:
        // accurate splits a console line at wide gaps and can miss a piece, like "[ OK ] Reached").
        let fast = fastLines.filter { line in
            let covered = accurate.reduce(CGFloat(0)) { sum, read in
                let common = read.rect.intersection(line.rect)
                return common.isNull || common.height < line.rect.height / 2 ? sum : sum + common.width
            }
            return covered < 0.9 * line.rect.width
        }
        let lines = (accurate + fast).map { line in
            Line(
                text: line.text, confidence: line.confidence,
                rect: CGRect(
                    x: area.minX + line.rect.minX / factor, y: area.minY + line.rect.minY / factor, width: line.rect.width / factor,
                    height: line.rect.height / factor
                ).integral)
        }
        return joined(lines)
    }

    /// `lines` top to bottom, with neighbours on one row joined when the gap between them is under a letter's
    /// height (accurate splits a console's wide-spaced words: "NE", "OCR", "CHECK 4271"); overlapping ones (a
    /// fast reading beside accurate pieces) are left apart.
    static func joined(_ lines: [Line]) -> [Line] {
        let ordered = lines.sorted { ($0.rect.midY, $0.rect.minX) < ($1.rect.midY, $1.rect.minX) }
        var rows: [[Line]] = []
        for line in ordered {
            if let last = rows.last?.last, abs(last.rect.midY - line.rect.midY) < min(last.rect.height, line.rect.height) / 2 {
                rows[rows.count - 1].append(line)
            } else {
                rows.append([line])
            }
        }
        var result: [Line] = []
        for row in rows {
            var current: Line?
            for line in row.sorted(by: { $0.rect.minX < $1.rect.minX }) {
                guard var joining = current else {
                    current = line
                    continue
                }
                let gap = line.rect.minX - joining.rect.maxX
                if gap >= -max(joining.rect.height, line.rect.height) / 3, gap < max(joining.rect.height, line.rect.height) {
                    joining.text += " " + line.text
                    joining.rect = joining.rect.union(line.rect)
                    joining.confidence = min(joining.confidence, line.confidence)
                    current = joining
                } else {
                    result.append(joining)
                    current = line
                }
            }
            if let current { result.append(current) }
        }
        return result.sorted { ($0.rect.minY, $0.rect.minX) < ($1.rect.minY, $1.rect.minX) }
    }

    /// Overlap of the quarters a dense screen is read in, and the margin each gets (text at an image's very edge
    /// is often not read).
    static let quarterOverlap = 48
    static let quarterMargin = 16

    /// `.accurate` lines of `image` read in four overlapping quarters, each enlarged twice (a console's 16-pixel
    /// letters were misread at their size: "UMPANF DCR CHFCK" for "VMPANE OCR CHECK") inside a margin; a line two
    /// quarters both read is kept once (the longer reading).
    private static func quarters(of image: CGImage) throws -> [Line] {
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let half = CGSize(width: image.width / 2, height: image.height / 2)
        var found: [Line] = []
        for row in 0..<2 {
            for column in 0..<2 {
                let quarter = CGRect(
                    x: CGFloat(column) * half.width - CGFloat(quarterOverlap), y: CGFloat(row) * half.height - CGFloat(quarterOverlap),
                    width: half.width + CGFloat(2 * quarterOverlap), height: half.height + CGFloat(2 * quarterOverlap)
                ).intersection(bounds)
                guard let crop = image.cropping(to: quarter), let framed = framed(crop, margin: quarterMargin) else { continue }
                for line in try lines(in: framed, level: .accurate) {
                    var moved = line
                    let rect = line.rect.offsetBy(dx: -CGFloat(quarterMargin), dy: -CGFloat(quarterMargin))
                    moved.rect = CGRect(
                        x: quarter.minX + rect.minX / 2, y: quarter.minY + rect.minY / 2, width: rect.width / 2, height: rect.height / 2)
                    if let twin = found.firstIndex(where: {
                        $0.rect.overlaps(moved.rect, share: 0.5) || moved.rect.overlaps($0.rect, share: 0.5)
                    }) {
                        if moved.text.count > found[twin].text.count { found[twin] = moved }
                    } else {
                        found.append(moved)
                    }
                }
            }
        }
        return found
    }

    /// `image` enlarged twice inside a black margin.
    private static func framed(_ image: CGImage, margin: Int) -> CGImage? {
        guard
            let context = CGContext(
                data: nil, width: image.width * 2 + 2 * margin, height: image.height * 2 + 2 * margin, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: context.width, height: context.height))
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: margin, y: margin, width: image.width * 2, height: image.height * 2))
        return context.makeImage()
    }

    /// Lines in `image`'s own pixels, origin top left.
    private static func lines(in image: CGImage, level: VNRequestTextRecognitionLevel) throws -> [Line] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = level
        request.usesLanguageCorrection = false  // UI labels are names, not prose
        try VNImageRequestHandler(cgImage: image).perform([request])
        let width = Double(image.width), height = Double(image.height)
        return (request.results ?? []).compactMap { observation in
            guard let best = observation.topCandidates(1).first else { return nil }
            // Vision's box is normalized with its origin at the bottom left.
            let box = observation.boundingBox
            return Line(
                text: best.string, confidence: best.confidence,
                rect: CGRect(x: box.minX * width, y: (1 - box.maxY) * height, width: box.width * width, height: box.height * height))
        }
    }

    private static func enlarged(_ image: CGImage) -> CGImage? {
        guard
            let context = CGContext(
                data: nil, width: image.width * 2, height: image.height * 2, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width * 2, height: image.height * 2))
        return context.makeImage()
    }
}

extension CGRect {
    /// Width × height; 0 for the null rectangle (an empty intersection).
    fileprivate var area: CGFloat { isNull ? 0 : width * height }

    /// Whether more than `share` of `other`'s area lies in this rectangle.
    fileprivate func overlaps(_ other: CGRect, share: CGFloat) -> Bool { intersection(other).area > share * other.area }
}
