import Foundation
import Testing

@testable import VMPaneHost

// Golden autounattend.xml per input variant: `Golden/<name>.xml`. Regenerate with VMPANE_UPDATE_GOLDEN=1 and
// review the diff against the S1-proven file (spikes/s01-win-qemu-boot/autounattend.xml).

private let accepted = Date(timeIntervalSince1970: 1_791_590_400)

private func expectGolden(_ name: String, _ text: String, sourceFile: String = #filePath) throws {
    let golden = URL(fileURLWithPath: sourceFile).deletingLastPathComponent().appendingPathComponent("Golden/\(name).xml")
    if ProcessInfo.processInfo.environment["VMPANE_UPDATE_GOLDEN"] == "1" {
        try text.write(to: golden, atomically: true, encoding: .utf8)
        return
    }
    #expect(
        text == (try String(contentsOf: golden, encoding: .utf8)), "differs from Golden/\(name).xml (VMPANE_UPDATE_GOLDEN=1 regenerates)")
    // Well-formed XML, with the Windows unattend namespace.
    let document = try XMLDocument(data: Data(text.utf8))
    #expect(document.rootElement()?.uri == "urn:schemas-microsoft-com:unattend")
}

@Test func englishProWithAGenericKey() throws {
    let input = UnattendInput(
        locale: "en-US", timeZone: "Pacific Standard Time", computerName: "WIN11", userName: "vmpane", password: "s3cret!",
        eulaAcceptedAt: accepted)
    try expectGolden("en-US-pro", try AutounattendGenerator.generate(input))
}

@Test func vietnameseHomeWithAProductKeyAndEscapedValues() throws {
    let input = UnattendInput(
        locale: "vi-VN", inputLocale: "en-US", timeZone: "SE Asia Standard Time", computerName: "MAY-AO", userName: "Tiến & Co",
        password: "<a&b>\"c'", editionName: "Windows 11 Home", productKey: "AAAAA-BBBBB-CCCCC-DDDDD-EEEEE", eulaAcceptedAt: accepted)
    let text = try AutounattendGenerator.generate(input)
    #expect(text.contains("<Value>&lt;a&amp;b&gt;&quot;c&apos;</Value>"))
    #expect(text.contains("<Name>Tiến &amp; Co</Name>"))
    try expectGolden("vi-VN-home-key", text)
}

@Test func tpmBypassOnlyWhenAsked() throws {
    var input = UnattendInput(
        locale: "en-US", timeZone: "UTC", computerName: "WIN11", userName: "vmpane", password: "x", eulaAcceptedAt: accepted)
    #expect(!(try AutounattendGenerator.generate(input)).contains("LabConfig"))
    input.bypassTPMChecks = true
    let text = try AutounattendGenerator.generate(input)
    #expect(text.contains("LabConfig /v BypassTPMCheck") && text.contains("LabConfig /v BypassSecureBootCheck"))
    try expectGolden("en-US-tpm-bypass", text)
}

@Test func invalidInputIsRefusedBeforeSetupSeesIt() {
    let base = UnattendInput(
        locale: "en-US", timeZone: "UTC", computerName: "WIN11", userName: "vmpane", password: "x", eulaAcceptedAt: accepted)
    func refuses(_ error: UnattendError, _ change: (inout UnattendInput) -> Void) {
        var input = base
        change(&input)
        #expect(throws: error) { try AutounattendGenerator.generate(input) }
    }
    refuses(.eulaNotAccepted) { $0.eulaAcceptedAt = nil }
    refuses(.invalidComputerName("THIS-NAME-IS-TOO-LONG")) { $0.computerName = "THIS-NAME-IS-TOO-LONG" }
    refuses(.invalidComputerName("12345")) { $0.computerName = "12345" }
    refuses(.invalidComputerName("a b")) { $0.computerName = "a b" }
    refuses(.invalidUserName("Administrator")) { $0.userName = "Administrator" }
    refuses(.invalidUserName("a/b")) { $0.userName = "a/b" }
    refuses(.invalidUserName("...")) { $0.userName = "..." }
    refuses(.invalidProductKey) { $0.productKey = "AAAAA-BBBBB" }
    refuses(.invalidLocale("english")) { $0.locale = "english" }
    refuses(.invalidPassword) { $0.password = "a\u{0}b" }
}

@Test func macTimeZonesMapToWindowsIDs() {
    #expect(UnattendInput.windowsTimeZone(for: "Asia/Ho_Chi_Minh") == "SE Asia Standard Time")
    #expect(UnattendInput.windowsTimeZone(for: "Europe/Berlin") == "W. Europe Standard Time")
    #expect(UnattendInput.windowsTimeZone(for: "Not/AZone") == "UTC")
}

/// A value that looks like a template field stays text.
@Test func valuesAreNeverReadAsFields() throws {
    let input = UnattendInput(
        locale: "en-US", timeZone: "UTC", computerName: "WIN11", userName: "vmpane", password: "{{USER}}{{LAB_CONFIG}}",
        eulaAcceptedAt: accepted)
    let text = try AutounattendGenerator.generate(input)
    #expect(text.contains("<Value>{{USER}}{{LAB_CONFIG}}</Value>"))
    #expect(!text.contains("LabConfig"))
}

/// VMPane shuts Windows down once install.ps1 reports its tools installed: every first-logon command after it
/// could be cut short, so the password cleanup must come first and the tools last.
@Test func guestToolsRunAfterThePasswordIsRemoved() throws {
    let input = UnattendInput(
        locale: "en-US", timeZone: "Pacific Standard Time", computerName: "WIN11", userName: "vmpane", password: "s3cret!",
        eulaAcceptedAt: accepted)
    let document = try XMLDocument(data: Data(try AutounattendGenerator.generate(input).utf8))
    let commands = try document.nodes(forXPath: "//*[local-name()='FirstLogonCommands']/*[local-name()='SynchronousCommand']")
    func value(_ node: XMLNode, _ name: String) throws -> String {
        try node.nodes(forXPath: "*[local-name()='\(name)']").first?.stringValue ?? ""
    }
    let ordered = try commands.sorted { try Int(value($0, "Order"))! < Int(value($1, "Order"))! }.map { try value($0, "CommandLine") }
    #expect(ordered.last?.contains("install.ps1") == true)
    #expect(ordered.dropLast().contains { $0.contains("DefaultPassword") })
    #expect(ordered.dropLast().contains { $0.contains("Panther") })
}
