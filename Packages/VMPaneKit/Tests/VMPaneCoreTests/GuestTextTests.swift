import Testing

@testable import VMPaneCore

@Test func guestTextLosesControlAndBidiCharacters() {
    #expect(GuestText.clean("Save\u{202E}txt.exe\u{0007}") == "Savetxt.exe")
    #expect(GuestText.clean("  Network &\n\tinternet  ") == "Network & internet")
    #expect(GuestText.clean("👩\u{200D}💻 Dev") == "👩\u{200D}💻 Dev")
    #expect(GuestText.clean(String(repeating: "a", count: 200)).count == 120)
    #expect(GuestText.clean("می\u{200C}خواهم") == "می\u{200C}خواهم", "the non-joiner stays")
}
