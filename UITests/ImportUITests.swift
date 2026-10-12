import AppKit
import XCTest

/// A Parallels VM imported like a user does it: the .pvm opened with VMPane (as from Finder's Open With) shows the
/// import sheet, Import converts it into the library. Run by `itest/scenarios/import-parallels.sh`, which passes the
/// .pvm and the support directory (xcodebuild hands `TEST_RUNNER_`-prefixed variables to the tests) and then boots
/// the imported VM. Skipped without them, as in `ui-smoke`.
final class ImportUITests: XCTestCase {
    @MainActor
    func testAParallelsVMOpenedWithVMPaneIsImported() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let pvm = environment["VMPANE_ITEST_PVM"], let support = environment["VMPANE_ITEST_SUPPORT"] else {
            throw XCTSkip("run by itest/scenarios/import-parallels.sh")
        }
        continueAfterFailure = false
        let app = AppUnderTest.app(for: self)
        app.launchEnvironment["VMPANE_SUPPORT_DIR"] = support
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        // The instance just launched (a VMPane the user runs has the same bundle id).
        let launched = NSWorkspace.shared.runningApplications
            .filter { $0.bundleIdentifier == "app.vmpane.mac" }
            .max { ($0.launchDate ?? .distantPast) < ($1.launchDate ?? .distantPast) }
        let appURL = try XCTUnwrap(launched?.bundleURL)
        _ = try await NSWorkspace.shared.open(
            [URL(fileURLWithPath: pvm)], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())

        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 10), "opening the .pvm shows the import sheet")
        let importButton = sheet.buttons["Import"]
        XCTAssertTrue(importButton.waitForExistence(timeout: 30))
        let readable = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: importButton)
        XCTAssertEqual(XCTWaiter().wait(for: [readable], timeout: 30), .completed, "the .pvm was read")
        importButton.click()
        // Until the sheet closes (done) or says what went wrong; the progress is logged, so a stall shows.
        let problem = sheet.descendants(matching: .any)["import-problem"]
        let deadline = Date().addingTimeInterval(900)
        var logged = Date.distantPast
        while sheet.exists, Date() < deadline {
            if problem.exists { XCTFail("the import failed: \(problem.label)"); return }
            if Date().timeIntervalSince(logged) > 30 {
                print("import progress: \(sheet.progressIndicators.firstMatch.value ?? "none")")
                logged = Date()
            }
            _ = sheet.waitForNonExistence(timeout: 2)
        }
        XCTAssertFalse(sheet.exists, "the import finished (the sheet closes)")
        app.terminate()
    }
}
