import AppKit
import XCTest

/// A running VM's window, used as a person does: what only the app may do to a VM (share folders, cancel an
/// install). Run by itest scenarios (`it_share_live`, `it_cancel_install_in_window` in itest/lib/common.sh) against
/// an app signed with a Developer ID, whose helpers take these changes from the app's own windows only. The
/// scenario shows the window (`vm.display.show`) of the helper at `VMPANE_ITEST_HELPER_APP`. Skipped without it.
final class VMWindowUITests: XCTestCase {
    private struct Share: Decodable {
        var path: String
        var readOnly: Bool
    }

    /// The VM's window, in front.
    @MainActor
    private func vmWindow() throws -> (XCUIApplication, XCUIElement) {
        guard let helper = AppUnderTest.environment["VMPANE_ITEST_HELPER_APP"] else {
            throw XCTSkip("run by an itest scenario")
        }
        continueAfterFailure = false
        // XCUITest finds a running app by its bundle id: with another VM's helper running it may drive that one.
        let helpers = NSRunningApplication.runningApplications(withBundleIdentifier: "app.vmpane.mac.vm")
        guard helpers.count == 1 else {
            XCTFail("\(helpers.count) VMPane VMs run (pids \(helpers.map(\.processIdentifier))): stop all but the test's")
            throw XCTSkip("not the only VM")
        }
        let vm = XCUIApplication(url: URL(fileURLWithPath: helper))
        vm.activate()
        let window = vm.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 30), "the VM's window is shown")
        return (vm, window)
    }

    /// Adds the folders of `VMPANE_ITEST_SHARES` (`[{path, readOnly}]`) in the VM's settings and applies them while
    /// it runs: each must take effect at once.
    @MainActor
    func testFoldersSharedWhileTheVMRuns() throws {
        guard let json = AppUnderTest.environment["VMPANE_ITEST_SHARES"] else { throw XCTSkip("run by an itest scenario") }
        let shares = try JSONDecoder().decode([Share].self, from: Data(json.utf8))
        let (vm, window) = try vmWindow()
        window.toolbars.buttons["Settings"].firstMatch.click()
        let sheet = window.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 10))
        for share in shares {
            sheet.buttons["Add Folder…"].click()
            // The open panel: go to the folder (⇧⌘G), then Open chooses it.
            let panel = vm.dialogs.firstMatch
            XCTAssertTrue(panel.waitForExistence(timeout: 10), "Add Folder… shows an open panel")
            panel.typeKey("g", modifierFlags: [.command, .shift])
            let path = panel.textFields["PathTextField"]
            XCTAssertTrue(path.waitForExistence(timeout: 10), "⇧⌘G asks for a folder")
            path.typeKey("a", modifierFlags: .command)  // it offers the last folder
            path.typeText(share.path + "\r")
            XCTAssertTrue(panel.sheets["GoToWindow"].waitForNonExistence(timeout: 10), "the panel went to the folder")
            let open = panel.buttons["Open"]
            XCTAssertTrue(open.waitForExistence(timeout: 5))
            let opened = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: open)
            XCTAssertEqual(XCTWaiter().wait(for: [opened], timeout: 10), .completed)
            open.click()
            XCTAssertTrue(panel.waitForNonExistence(timeout: 10))
            let name = URL(fileURLWithPath: share.path).lastPathComponent
            let readOnly = sheet.checkBoxes["Read only: \(name)"]
            XCTAssertTrue(readOnly.waitForExistence(timeout: 5), "\(name) is in the list")
            if share.readOnly { readOnly.click() }
        }
        sheet.buttons["Apply"].click()
        XCTAssertTrue(sheet.staticTexts["Takes effect: Applied"].waitForExistence(timeout: 60), "sharing took effect live")
        sheet.buttons["Done"].click()
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 5))
    }

    /// Cancels the Windows install shown in the VM's window (`VMPANE_ITEST_CANCEL_INSTALL=1`), confirming it.
    @MainActor
    func testWindowsInstallCancelledFromItsWindow() throws {
        guard AppUnderTest.environment["VMPANE_ITEST_CANCEL_INSTALL"] == "1" else { throw XCTSkip("run by an itest scenario") }
        let (vm, window) = try vmWindow()
        let cancel = window.buttons["Cancel Install…"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 120), "the install's progress offers to cancel")
        cancel.click()
        let confirm = vm.buttons["Cancel Installation"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), "the app asks first")
        confirm.click()
        XCTAssertTrue(cancel.waitForNonExistence(timeout: 180), "the install ended")
    }
}
