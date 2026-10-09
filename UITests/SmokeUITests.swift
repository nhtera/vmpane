import XCTest

/// Launch smoke test: the app starts and shows its main window.
final class SmokeUITests: XCTestCase {
    @MainActor
    func testLaunchShowsMainWindow() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
    }
}
