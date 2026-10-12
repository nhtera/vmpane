import XCTest

/// Launch smoke test: the app starts and shows its main window (on an empty support directory of its own).
final class SmokeUITests: XCTestCase {
    @MainActor
    func testLaunchShowsMainWindow() {
        let support = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("vp-ui-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: support) }
        let app = AppUnderTest.app(for: self)
        app.launchEnvironment["VMPANE_SUPPORT_DIR"] = support.path
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
    }
}
