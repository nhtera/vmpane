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
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 5), "Cancel closes the wizard")
    }

    @MainActor
    func testLibraryAndWizardPassTheAccessibilityAudit() throws {
        let app = launch()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        // The window and its sheets are audited, not the menu bar. Not the app's to fix: SwiftUI's window and sheet
        // hosts and the split view's column hosts are unnamed groups the size of their window or sheet (VoiceOver
        // names them by the window); the title bar's buttons and title are macOS's own. Everything else is audited.
        let titleBarButtons = window.buttons.matching(NSPredicate(format: "identifier BEGINSWITH '_XCUI:'"))
        func excuse(_ issue: XCUIAccessibilityAuditIssue) -> Bool {
            guard let element = issue.element else { return false }
            if !window.frame.intersects(element.frame) { return true }  // the menu bar: this test audits the window
            if issue.auditType == .parentChild {
                return titleBarButtons.allElementsBoundByIndex.contains { $0.frame.contains(element.frame) }
            }
            if issue.auditType == .contrast {
                // The title macOS draws in the title bar; or window text under an open sheet, where the audit samples
                // the sheet's pixels instead of the text's.
                if element.elementType == .staticText && element.value as? String == window.title { return true }
                return app.sheets.allElementsBoundByIndex.contains { sheet in
                    sheet.frame.contains(element.frame)
                        && !sheet.staticTexts.matching(NSPredicate(format: "value == %@", element.value as? String ?? "")).firstMatch.exists
                }
            }
            guard issue.auditType == .sufficientElementDescription, element.elementType == .group else { return false }
            let sheetHost = app.sheets.allElementsBoundByIndex.contains { $0.frame == element.frame }
            return sheetHost || (element.frame.minY == window.frame.minY && element.frame.height == window.frame.height)
        }
        let windowHost: (XCUIAccessibilityAuditIssue) -> Bool = { issue in
            let excused = excuse(issue)
            if !excused {  // the failure names only the audit; this says which element
                print("audit issue: \(issue.compactDescription) on \(issue.element?.debugDescription.prefix(300) ?? "no element")")
            }
            return excused
        }
        try app.performAccessibilityAudit(for: .all, windowHost)
        app.typeKey("n", modifierFlags: .command)
        XCTAssertTrue(app.sheets.firstMatch.waitForExistence(timeout: 5))
        try app.performAccessibilityAudit(for: .all, windowHost)
    }
}
