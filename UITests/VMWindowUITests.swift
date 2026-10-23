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
        sheet.descendants(matching: .any)["section Sharing"].firstMatch.click()  // the section with the shared folders
        XCTAssertTrue(sheet.buttons["Add Folder…"].waitForExistence(timeout: 5))
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

    /// The VM's window and its settings sheet pass the accessibility audit (`VMPANE_ITEST_AUDIT=1`).
    @MainActor
    func testVMWindowPassesTheAccessibilityAudit() throws {
        guard AppUnderTest.environment["VMPANE_ITEST_AUDIT"] == "1" else { throw XCTSkip("run by an itest scenario") }
        let (vm, window) = try vmWindow()
        XCTAssertTrue(window.images["\(window.title) screen"].exists, "VoiceOver finds the VM's screen, by its name")
        try AppUnderTest.audit(vm, window: window)
        window.toolbars.buttons["Settings"].firstMatch.click()
        let sheet = window.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 10))
        // Audited once it has slid in: mid-animation its controls report no actions yet.
        let settled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == true"), object: sheet.buttons["Done"])
        XCTAssertEqual(XCTWaiter().wait(for: [settled], timeout: 10), .completed)
        try AppUnderTest.audit(vm, window: window)
        // Every section the VM has, each in its turn.
        for title in ["Hardware", "Display", "Sharing", "AI agents", "Network", "Port Forwarding"] {
            let section = sheet.descendants(matching: .any)["section \(title)"].firstMatch
            guard section.exists else { continue }
            section.click()
            try AppUnderTest.audit(vm, window: window)
        }
        sheet.buttons["Done"].click()
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 5))
    }

    /// The running VM has its own Dock tile, whose menu acts on it: Pause, then Resume (`VMPANE_ITEST_DOCK=1`).
    @MainActor
    func testDockMenuActsOnTheVM() throws {
        guard AppUnderTest.environment["VMPANE_ITEST_DOCK"] == "1" else { throw XCTSkip("run by an itest scenario") }
        let dock = XCUIApplication(bundleIdentifier: "com.apple.dock")
        // (the Dock names a tile after its app's file)
        let tiles = dock.descendants(matching: .dockItem).matching(NSPredicate(format: "title IN %@", ["VMPane VM", "VMPaneVM"]))
        XCTAssertTrue(tiles.firstMatch.waitForExistence(timeout: 10), "the VM has a Dock tile")
        let (_, window) = try vmWindow()
        XCTAssertEqual(tiles.count, 1, "one tile for the one running VM")
        /// A hidden Dock shows when the pointer reaches its screen edge (whichever edge that is, by the tile's place).
        func reveal() {
            let tile = tiles.firstMatch.frame
            guard !tiles.firstMatch.isHittable, let screen = NSScreen.main?.frame else { return }
            let edge = CGPoint(
                x: tile.midX < screen.minX + 10 ? screen.minX + 1 : tile.midX > screen.maxX - 10 ? screen.maxX - 1 : tile.midX,
                y: tile.midY > screen.maxY - 10 ? screen.maxY - 1 : tile.midY)
            let origin = window.coordinate(withNormalizedOffset: .zero)
            origin.withOffset(CGVector(dx: edge.x - window.frame.minX, dy: edge.y - window.frame.minY)).hover()
            let shown = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == true"), object: tiles.firstMatch)
            _ = XCTWaiter().wait(for: [shown], timeout: 5)
        }
        func choose(_ title: String) {
            reveal()
            tiles.firstMatch.rightClick()
            let item = dock.menuItems[title]
            XCTAssertTrue(item.waitForExistence(timeout: 5), "the Dock menu offers \(title)")
            XCTAssertTrue(dock.menuItems["Show Window"].exists && dock.menuItems["Take Snapshot"].exists)
            item.click()
        }
        choose("Pause")
        choose("Resume")  // offered only once the VM paused
        reveal()
        tiles.firstMatch.rightClick()
        XCTAssertTrue(dock.menuItems["Pause"].waitForExistence(timeout: 5), "running again")
        dock.typeKey(.escape, modifierFlags: [])
    }

    /// The VM's app has a menu bar with Quit; Quit while the VM runs asks first, and Cancel keeps it running
    /// (`VMPANE_ITEST_DOCK=1`). (⌘Q typed into the VM's screen goes to the guest, as other keys do.)
    @MainActor
    func testQuitAsksWhileTheVMRuns() throws {
        guard AppUnderTest.environment["VMPANE_ITEST_DOCK"] == "1" else { throw XCTSkip("run by an itest scenario") }
        let (vm, window) = try vmWindow()
        let appMenu = vm.menuBars.menuBarItems["VMPane VM"]
        XCTAssertTrue(appMenu.exists, "the app menu")
        appMenu.click()
        let quit = vm.menuBars.menuItems["Quit VMPane VM"]
        XCTAssertTrue(quit.waitForExistence(timeout: 5))
        quit.click()
        let asked = vm.buttons["Stop and Quit"]
        XCTAssertTrue(asked.waitForExistence(timeout: 5), "Quit asks before stopping a running VM")
        vm.buttons["Cancel"].firstMatch.click()
        XCTAssertTrue(asked.waitForNonExistence(timeout: 5))
        XCTAssertTrue(window.exists, "Cancel keeps the VM's app")
    }

    /// While an agent types in the VM (the scenario's agent, `VMPANE_ITEST_AGENT_HUD=1`), the window's HUD offers Take
    /// Over: pressed, it turns to Resume (the agent's calls are refused meanwhile, which the scenario checks); Resume
    /// hands the VM back.
    @MainActor
    func testAgentHUDTakesOverAndResumes() throws {
        guard AppUnderTest.environment["VMPANE_ITEST_AGENT_HUD"] == "1" else { throw XCTSkip("run by an itest scenario") }
        let (vm, _) = try vmWindow()
        let takeOver = vm.buttons["Take Over"]
        XCTAssertTrue(takeOver.waitForExistence(timeout: 30), "the HUD shows while the agent acts")
        takeOver.click()
        let resume = vm.buttons["Resume"]
        XCTAssertTrue(resume.waitForExistence(timeout: 5), "taken over")
        Thread.sleep(forTimeInterval: 4)  // the agent's next calls are refused meanwhile
        resume.click()
        XCTAssertTrue(takeOver.waitForExistence(timeout: 5), "handed back")
    }

    /// With the Mac nearly out of memory (the scenario fakes it, `VMPANE_ITEST_LOW_MEMORY=1`), the running VM's window
    /// warns; shut down from its toolbar, the VM's Start asks first: Cancel keeps it off, Start Anyway starts it.
    @MainActor
    func testLowMemoryWarnsAndAsksBeforeAStart() throws {
        guard AppUnderTest.environment["VMPANE_ITEST_LOW_MEMORY"] == "1" else { throw XCTSkip("run by an itest scenario") }
        let (vm, window) = try vmWindow()
        let warning = window.descendants(matching: .any)["low-memory-warning"]
        XCTAssertTrue(warning.waitForExistence(timeout: 20), "the running VM's window warns")
        window.buttons["Shut Down"].firstMatch.click()
        let start = window.buttons["Start"].firstMatch
        XCTAssertTrue(start.waitForExistence(timeout: 90), "the stopped VM's window offers Start")
        XCTAssertTrue(warning.waitForNonExistence(timeout: 10), "a stopped VM shows no warning")
        for answer in ["Cancel", "Start Anyway"] {
            start.click()
            let inSheet = window.sheets.buttons[answer]
            let inDialog = vm.dialogs.buttons[answer]
            let asked = Date().addingTimeInterval(10)
            while !inSheet.exists, !inDialog.exists, Date() < asked { _ = inSheet.waitForExistence(timeout: 1) }
            XCTAssertTrue(inSheet.exists || inDialog.exists, "Start asks first on a Mac low on memory")
            (inSheet.exists ? inSheet : inDialog).click()
            if answer == "Cancel" {
                XCTAssertTrue(start.waitForExistence(timeout: 5), "Cancel keeps the VM off")
            }
        }
        XCTAssertTrue(window.buttons["Shut Down"].firstMatch.waitForExistence(timeout: 60), "Start Anyway starts the VM")
    }

    /// Cancels the Windows install shown in the VM's window (`VMPANE_ITEST_CANCEL_INSTALL=1`), confirming it.
    @MainActor
    func testWindowsInstallCancelledFromItsWindow() throws {
        guard AppUnderTest.environment["VMPANE_ITEST_CANCEL_INSTALL"] == "1" else { throw XCTSkip("run by an itest scenario") }
        let (vm, window) = try vmWindow()
        let cancel = window.buttons["Cancel Install…"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 120), "the install's progress offers to cancel")
        cancel.click()
        // The alert's own button (a sheet on the window, or a dialog), not its Touch Bar copy.
        let inSheet = window.sheets.buttons["Cancel Installation"]
        let inDialog = vm.dialogs.buttons["Cancel Installation"]
        let asked = Date().addingTimeInterval(10)
        while !inSheet.exists, !inDialog.exists, Date() < asked { _ = inSheet.waitForExistence(timeout: 1) }
        XCTAssertTrue(inSheet.exists || inDialog.exists, "the app asks first")
        (inSheet.exists ? inSheet : inDialog).click()
        XCTAssertTrue(cancel.waitForNonExistence(timeout: 180), "the install ended")
    }
}
