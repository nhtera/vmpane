import XCTest

/// The library and the wizard, driven like a user (needs an unlocked GUI session).
final class LibraryUITests: XCTestCase {
    private var support: URL!

    override func setUp() {
        continueAfterFailure = false
        support = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("vp-ui-\(UUID().uuidString.prefix(8))")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: support)
    }

    /// An empty library in its own support directory, past the welcome.
    @MainActor
    private func launch() -> XCUIApplication {
        let app = AppUnderTest.app(for: self)
        app.launchEnvironment["VMPANE_SUPPORT_DIR"] = support.path
        app.launch()
        return app
    }

    @MainActor
    func testEmptyLibraryOffersTheSystems() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["Create Your First VM"].waitForExistence(timeout: 10))
        app.buttons["Fedora"].click()
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 5), "a card opens the new-VM sheet")
        XCTAssertTrue(sheet.buttons["Fedora"].isSelected)
        sheet.buttons["Cancel"].click()
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 5))
    }

    /// The sheet's front: a Linux card is ready to create as it is; Windows needs its ISO, so Return goes to Customize;
    /// Customize… walks the steps, and Back returns to the cards.
    @MainActor
    func testNewVMSheetCardsAndCustomize() {
        let app = launch()
        app.typeKey("n", modifierFlags: .command)
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 5))
        sheet.buttons["Ubuntu"].click()
        XCTAssertTrue(sheet.buttons["Ubuntu"].isSelected)
        XCTAssertTrue(sheet.buttons["Create"].isEnabled, "Ubuntu needs nothing more")
        sheet.buttons["Customize…"].click()
        XCTAssertTrue(sheet.buttons["Choose an arm64 ISO…"].waitForExistence(timeout: 5), "Customize starts at the installer")
        sheet.buttons["Back"].click()
        XCTAssertTrue(sheet.buttons["Windows 11"].waitForExistence(timeout: 5), "Back returns to the cards")
        sheet.buttons["Windows 11"].click()
        XCTAssertFalse(sheet.buttons["Create"].isEnabled, "no Windows ISO yet")
        sheet.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(sheet.buttons["Choose the Windows ISO…"].waitForExistence(timeout: 5), "Return goes where the ISO is chosen")
        sheet.buttons["Cancel"].click()
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 5), "Cancel closes the sheet")
    }

    @MainActor
    func testLibraryWizardAndSettingsPassTheAccessibilityAudit() throws {
        let app = launch()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        try AppUnderTest.audit(app, window: window)
        app.typeKey("n", modifierFlags: .command)
        XCTAssertTrue(app.sheets.firstMatch.waitForExistence(timeout: 5))
        try AppUnderTest.audit(app, window: window)
        app.sheets.firstMatch.buttons["Cancel"].click()
        XCTAssertTrue(app.sheets.firstMatch.waitForNonExistence(timeout: 5))
        // (`window` is the first window, which Settings becomes once it is in front.)
        let settings = app.windows.matching(NSPredicate(format: "title != %@", window.title)).firstMatch
        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(settings.waitForExistence(timeout: 10), "⌘, opens Settings")
        try AppUnderTest.audit(app, window: settings)
    }
}
