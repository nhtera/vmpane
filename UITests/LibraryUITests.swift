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
        let app = XCUIApplication()
        app.launchEnvironment["VMPANE_SUPPORT_DIR"] = support.path
        app.launchArguments += ["-onboarded", "YES"]
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
        XCTAssertFalse(sheet.buttons["Continue"].isEnabled, "nothing chosen yet")
        sheet.buttons["Linux"].click()
        XCTAssertTrue(sheet.buttons["Continue"].isEnabled)
        sheet.buttons["Continue"].click()
        XCTAssertTrue(sheet.buttons["Choose an arm64 ISO…"].waitForExistence(timeout: 5))
        XCTAssertFalse(sheet.buttons["Continue"].isEnabled, "no installer chosen")
        sheet.buttons["Back"].click()
        sheet.buttons["Cancel"].click()
        XCTAssertFalse(sheet.exists)
    }

    @MainActor
    func testLibraryAndWizardPassTheAccessibilityAudit() throws {
        let app = launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        try app.performAccessibilityAudit()
        app.typeKey("n", modifierFlags: .command)
        XCTAssertTrue(app.sheets.firstMatch.waitForExistence(timeout: 5))
        try app.performAccessibilityAudit()
    }
}
