// Text on a screenshot, for scenarios that drive a guest's UI (macOS Setup Assistant): one JSON object per line,
// {"text", "x", "y", "w", "h"} in the image's pixels, origin top left. Vision's accurate recognizer, English.
// Usage: ocr <png>   (compiled by it_ocr in common.sh)
import Foundation
import Vision

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: ocr <png>\n".utf8))
    exit(2)
}
let url = URL(fileURLWithPath: CommandLine.arguments[1])
guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    FileHandle.standardError.write(Data("ocr: cannot read \(url.path)\n".utf8))
    exit(1)
}
let request = VNRecognizeTextRequest()
request.recognitionLevel = .accurate
request.recognitionLanguages = ["en-US"]
request.usesLanguageCorrection = false
try VNImageRequestHandler(cgImage: image).perform([request])
let width = Double(image.width), height = Double(image.height)
for observation in request.results ?? [] {
    guard let text = observation.topCandidates(1).first?.string else { continue }
    let box = observation.boundingBox  // normalized, origin bottom left
    let line: [String: Any] = [
        "text": text, "x": Int(box.minX * width), "y": Int((1 - box.maxY) * height),
        "w": Int(box.width * width), "h": Int(box.height * height),
    ]
    if let data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]) {
        print(String(decoding: data, as: UTF8.self))
    }
}
