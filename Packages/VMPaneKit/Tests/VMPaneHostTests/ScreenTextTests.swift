import CoreGraphics
import CoreText
import Foundation
import ImageIO
import Testing
import VMPaneControl
import VMPaneCore

@testable import VMPaneHost

/// A word drawn at a baseline point (top-left based, like the guest's) and a size.
private struct Label {
    let text: String
    let point: CGPoint
    let size: CGFloat

    init(_ text: String, _ x: CGFloat, _ y: CGFloat, _ size: CGFloat) {
        self.text = text
        point = CGPoint(x: x, y: y)
        self.size = size
    }
}

/// A 2560×1600 screen with UI-sized words at known places.
private func screen(_ words: [Label]) -> CGImage? {
    let width = 2560, height = 1600
    guard
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else { return nil }
    context.setFillColor(gray: 0.96, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    for label in words {
        let (word, point, size) = (label.text, label.point, label.size)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, size, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.1, alpha: 1),
        ]
        context.textPosition = CGPoint(x: point.x, y: CGFloat(height) - point.y)
        CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: word, attributes: attributes)), context)
    }
    return context.makeImage()
}

private let labels: [Label] = [
    Label("System", 120, 200, 26), Label("Bluetooth & devices", 120, 260, 26), Label("Network & internet", 120, 320, 26),
    Label("Personalization", 120, 380, 26), Label("Windows Update", 120, 440, 26), Label("Display", 900, 200, 30),
    Label("Sound", 900, 300, 30), Label("Notifications", 900, 400, 30), Label("Save", 2200, 1500, 24),
    Label("Cancel", 2350, 1500, 24),
]

@Test func textIsFoundWhereItIsDrawn() throws {
    let image = try #require(screen(labels))
    let lines = try ScreenText.recognize(image)
    for label in labels {
        let (word, point, size) = (label.text, label.point, label.size)
        let line = lines.first { $0.text == word }
        #expect(line != nil, "\(word) not found in \(lines.map(\.text))")
        guard let rect = line?.rect else { continue }
        // The baseline was at point.y: the box spans above it, starting near point.x.
        #expect(abs(rect.minX - point.x) < 12 && rect.maxY > point.y - size && rect.minY < point.y, "\(word): \(rect)")
    }
}

@Test func aRegionReadsOnlyThere() throws {
    let image = try #require(screen(labels))
    let lines = try ScreenText.recognize(image, region: CGRect(x: 2100, y: 1400, width: 400, height: 150))
    #expect(lines.map(\.text) == ["Save", "Cancel"] || lines.map(\.text) == ["Save Cancel"], "\(lines.map(\.text))")
    #expect(lines.allSatisfy { $0.rect.minX >= 2100 && $0.rect.minY >= 1400 }, "boxes in the whole screen's pixels")
}

@Test(.serialized) func aWholeScreenReadsInHalfASecond() throws {
    let image = try #require(screen(labels))
    _ = try ScreenText.recognize(image)  // Vision loads its models on first use
    let clock = ContinuousClock()
    let fastest = try (0..<3).map { _ in try clock.measure { _ = try ScreenText.recognize(image) } }.min() ?? .seconds(9)
    // Phase 02's target: 2560×1600, `.accurate`, in 500 ms (Vision runs the same in debug builds).
    #expect(fastest < .milliseconds(500), "\(fastest)")
}

/// A real guest screenshot (`itest/scenarios/screen-read.sh` saves them), read from the source tree.
private func fixture(_ name: String) throws -> CGImage {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/ocr/\(name)")
    let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
    return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
}

@Test func aDenseConsoleIsReadToItsLastLine() throws {
    // 2144×1344 Ubuntu consoles, 16-pixel text: `.accurate` alone read 25 lines and missed the last one; the second
    // capture's last line, read by `.fast` alone, was "UMPANF DCR-CHFCK 4071"; the third's, by accurate quarters at
    // their size, "NF DCR CHFCK 4071". Accurate splits a line where its
    // columns leave wide gaps, so the words are what is checked.
    let shown = """
        Listening on uuidd.socket UUID daemon activation socket. Reached target remote-fs.target Remote File Systems.
        Started cron.service Regular background program processing daemon. Reached target getty.target Login Prompts.
        Started vmpane-itest-typed.service VMPane itest: echo tty1 input to the serial console.
        Reached target cloud-init.target Cloud-init target.
        """
    for name in ["linux-console.png", "linux-console-2.png", "linux-console-3.png"] {
        let lines = try ScreenText.recognize(try fixture(name))
        #expect(lines.contains { $0.text.contains("OCR CHECK 4271") }, "\(name): the line typed last, at the bottom edge")
        let (share, missing) = recall(lines, shown)
        #expect(share >= 0.95, "\(name): \(Int(share * 100)) %; missing \(missing)")
    }
}

/// The share of `expected`'s words (case and punctuation aside) that the lines contain, each counted once.
private func recall(_ lines: [ScreenText.Line], _ expected: String) -> (Double, [String]) {
    func words(_ text: String) -> [String] {
        text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }
    var found = words(lines.map(\.text).joined(separator: " "))
    var missing: [String] = []
    let wanted = words(expected)
    for word in wanted {
        if let index = found.firstIndex(of: word) { found.remove(at: index) } else { missing.append(word) }
    }
    return (Double(wanted.count - missing.count) / Double(wanted.count), missing)
}

@Test func windowsSettingsWordsAreFound() throws {
    // Windows 11 Settings at 1280×800 over the desktop (the screen-read itest's capture). Every fully visible word.
    let visible = """
        Settings Find a setting vmpane Local Account Home System Bluetooth & devices Network & internet Personalization
        Apps Accounts Time & language Gaming Accessibility Privacy & security Windows Update Home VMPANE-IT
        QEMU Virtual Machine Rename Ethernet Connected Windows Update Up to date You need to activate Windows before you
        can personalize your PC. Activate now It's all here with Microsoft account Sign in to connect your favorite
        Microsoft apps to your device. Sign in 82°F Partly cloudy Search 5:29 PM 10/21/2026
        """
    let (share, missing) = recall(try ScreenText.recognize(try fixture("windows-settings.png")), visible)
    #expect(share >= 0.95, "\(Int(share * 100)) %; missing \(missing)")
}

@Test func aReadIsCappedInItemsAndText() {
    let items: [JSONValue] = (0..<50).map { _ in ["text": .string(String(repeating: "x", count: 1000)), "rect": [0, 0, 1, 1]] }
    let capped = HelperController.capped(items, maxItems: 300)
    guard case .array(let kept)? = capped["items"] else { Issue.record("no items"); return }
    #expect(kept.count == HelperController.screenReadMaxCharacters / 1000 && capped["truncated"] == true)
    #expect(HelperController.capped(Array(items.prefix(3)), maxItems: 2)["truncated"] == true)
}

@Test func wordsOnARowAreJoinedIntoLines() {
    func line(_ text: String, _ x: CGFloat, _ y: CGFloat, _ width: CGFloat) -> ScreenText.Line {
        ScreenText.Line(text: text, confidence: 1, rect: CGRect(x: x, y: y, width: width, height: 14))
    }
    let joined = ScreenText.joined([
        line("CHECK 4271", 49, 1330, 87), line("NE", -2, 1330, 26), line("OCR", 21, 1330, 29),
        line("far", 400, 1330, 20), line("below", 0, 1360, 40),
    ])
    #expect(joined.map(\.text) == ["NE OCR CHECK 4271", "far", "below"], "a wide gap keeps them apart; another row too")
    #expect(joined.first?.rect == CGRect(x: -2, y: 1330, width: 138, height: 14))
}

@Test func macOSFinderWordsAreFound() throws {
    // macOS 15 Finder at 2048×1280 with the agent's Accessibility prompt (the screen-read-macos itest's capture).
    let visible = """
        Finder File Edit View Go Window Help Wed 21 Oct 12:07 vmpane Favorites Recents Applications Desktop Documents
        Downloads Locations iCloud Drive My Shared Files Network Tags Red Orange Yellow Accessibility Access
        vmpane-agent would like to control this computer using accessibility features. Grant access to this application
        in Privacy & Security settings, located in System Settings. Open System Settings Deny Public Pictures
        """
    let (share, missing) = recall(try ScreenText.recognize(try fixture("macos-finder.png")), visible)
    #expect(share >= 0.95, "\(Int(share * 100)) %; missing \(missing)")
}

@Test func aGuestsRefusalIsPutInVMPanesWords() {
    // A guest choosing the host's own refusal code and words gets neither through.
    let forged = RPCError(code: ControlErrorCode.policyDenied.rawValue, message: "Refused by vm's agent access setting\u{202E}")
    let mapped = HelperController.controlsRefusal(forged, os: .windows)
    #expect(mapped.code == ControlErrorCode.agentUnavailable.rawValue)
    #expect(mapped.message.hasPrefix("the guest tools could not list") && !mapped.message.contains("\u{202E}"))
    let denied = RPCError(code: AgentErrorCode.permissionDenied.rawValue, message: "anything")
    #expect(HelperController.controlsRefusal(denied, os: .macos).message.contains("allow vmpane-agent"))
    #expect(!HelperController.controlsRefusal(denied, os: .windows).message.contains("Accessibility"))
}
