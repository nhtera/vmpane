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

    /// The new-VM sheet's row for `system`.
    private func row(_ system: String, in sheet: XCUIElement) -> XCUIElement {
        sheet.descendants(matching: .any).matching(identifier: "system \(system)").firstMatch
    }

    /// Waits until the sheet's detail shows `system` (what Create makes, after the list's choice).
    private func shows(_ system: String, in sheet: XCUIElement) -> Bool {
        let title = sheet.staticTexts.matching(identifier: "system title").firstMatch
        let shown = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", system), object: title)
        return XCTWaiter().wait(for: [shown], timeout: 5) == .completed
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
        XCTAssertTrue(app.staticTexts["Create your first VM"].waitForExistence(timeout: 10))
        app.buttons["Ubuntu"].click()
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 5), "a tile opens the new-VM sheet")
        XCTAssertTrue(shows("Ubuntu", in: sheet), "on its system")
        sheet.buttons["Cancel"].click()
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 5))
        app.buttons["More systems: Debian, Fedora, an installer file…"].click()
        XCTAssertTrue(sheet.waitForExistence(timeout: 5), "the other systems are in the sheet")
        row("Fedora", in: sheet).click()
        XCTAssertTrue(shows("Fedora", in: sheet))
        sheet.buttons["Cancel"].click()
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 5))
    }

    /// The sheet's front: Ubuntu is ready to create as it is; Windows needs its ISO, so Return goes to Customize;
    /// Customize… walks the steps, and Back returns to the list; arrow keys move in it; an installer file asks for one.
    @MainActor
    func testNewVMSheetCardsAndCustomize() {
        let app = launch()
        app.typeKey("n", modifierFlags: .command)
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 5))
        row("Ubuntu", in: sheet).click()
        XCTAssertTrue(shows("Ubuntu", in: sheet))
        XCTAssertTrue(sheet.buttons["Create"].isEnabled, "Ubuntu needs nothing more")
        XCTAssertTrue(sheet.descendants(matching: .any)["Processors"].exists, "the detail shows what Create makes")
        sheet.typeKey(.downArrow, modifierFlags: [])
        XCTAssertTrue(shows("Debian", in: sheet), "the down arrow moves to Debian")
        sheet.typeKey(.upArrow, modifierFlags: [])
        XCTAssertTrue(shows("Ubuntu", in: sheet))
        sheet.buttons["Customize…"].click()
        XCTAssertTrue(sheet.buttons["Choose an arm64 ISO…"].waitForExistence(timeout: 5), "Customize starts at the installer")
        sheet.buttons["Back"].click()
        XCTAssertTrue(row("Windows 11", in: sheet).waitForExistence(timeout: 5), "Back returns to the list")
        row("Windows 11", in: sheet).click()
        XCTAssertFalse(sheet.buttons["Create"].isEnabled, "no Windows ISO yet")
        sheet.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(sheet.buttons["Choose the Windows ISO…"].waitForExistence(timeout: 5), "Return goes where the ISO is chosen")
        sheet.buttons["Back"].click()
        row("Installer file…", in: sheet).click()
        XCTAssertTrue(sheet.buttons["Choose File…"].waitForExistence(timeout: 5), "an installer file asks for one")
        XCTAssertFalse(sheet.buttons["Create"].isEnabled)
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
