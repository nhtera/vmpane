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
    func testEmptyLibraryOffersANewVM() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["No Virtual Machines"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["New VM…"].exists)
    }

    @MainActor
    func testWizardWalksLinuxToTheInstallerStep() {
        let app = launch()
        app.typeKey("n", modifierFlags: .command)
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 5))
        XCTAssertTrue(sheet.buttons["macOS"].isSelected, "macOS is chosen at the start")
        XCTAssertTrue(sheet.buttons["Continue"].isEnabled)
        sheet.buttons["Linux"].click()
        XCTAssertTrue(sheet.buttons["Linux"].isSelected && !sheet.buttons["macOS"].isSelected)
        XCTAssertTrue(sheet.buttons["Continue"].isEnabled)
        sheet.buttons["Continue"].click()
        XCTAssertTrue(sheet.buttons["Choose an arm64 ISO…"].waitForExistence(timeout: 5))
        XCTAssertFalse(sheet.buttons["Continue"].isEnabled, "no installer chosen")
        sheet.buttons["Back"].click()
        sheet.buttons["Cancel"].click()
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 5), "Cancel closes the wizard")
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
