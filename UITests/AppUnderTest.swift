import XCTest

/// The app the UI tests drive: the one the itest scenario tests (`VMPANE_ITEST_APP`, e.g. a release candidate's,
/// mounted from its DMG), else the one this scheme built. xcodebuild hands `TEST_RUNNER_`-prefixed variables to the
/// tests without the prefix.
enum AppUnderTest {
    static var environment: [String: String] { ProcessInfo.processInfo.environment }

    /// The app, past the welcome unless `onboarded` is false, quit when `test` ends (one launched by URL would outlive
    /// it). A Release build's updater never asks whether to check for updates (Sparkle's question at the second launch).
    @MainActor static func app(for test: XCTestCase, onboarded: Bool = true) -> XCUIApplication {
        let app = environment["VMPANE_ITEST_APP"].map { XCUIApplication(url: URL(fileURLWithPath: $0)) } ?? XCUIApplication()
        app.launchArguments += ["-onboarded", onboarded ? "YES" : "NO", "-SUEnableAutomaticChecks", "NO"]
        test.addTeardownBlock { @MainActor in app.terminate() }
        return app
    }

    /// Every accessibility audit on `window` (and a sheet on it), not the menu bar. Not the app's to fix: SwiftUI's
    /// window and sheet hosts (also of the app's other windows, which the audit sees through) and the split view's column hosts are unnamed groups the size of their window or sheet
    /// (VoiceOver names them by the window); the title bar's buttons and title are macOS's own. Everything else is
    /// audited, and each issue that fails it is printed with its element (the failure names only the audit).
    @MainActor static func audit(_ app: XCUIApplication, window: XCUIElement) throws {
        try app.performAccessibilityAudit(for: .all) { issue in
            let excused = excused(issue, app: app, window: window)
            if !excused {
                print("audit issue: \(issue.compactDescription) on \(issue.element?.debugDescription.prefix(300) ?? "no element")")
            }
            return excused
        }
    }

    @MainActor private static func excused(_ issue: XCUIAccessibilityAuditIssue, app: XCUIApplication, window: XCUIElement) -> Bool {
        // SwiftUI's bridged title (a 14×16 group at the title bar's left) is listed in the content but names the
        // window as its parent; the audit cannot resolve it to an element. Any other issue needs its element.
        guard let element = issue.element else { return issue.auditType == .parentChild }
        if !window.frame.intersects(element.frame) { return true }  // the menu bar or another window
        switch issue.auditType {
        case .action:
            // SwiftUI pop-ups have AXPress (an Accessibility dump of the VM settings shows it on every one), yet the audit
            // reports one of them (Resolution) as missing its action, also once the sheet has settled.
            return element.elementType == .popUpButton
        case .parentChild:
            let titleBarButtons = window.buttons.matching(NSPredicate(format: "identifier BEGINSWITH '_XCUI:'"))
            return titleBarButtons.allElementsBoundByIndex.contains { $0.frame.contains(element.frame) }
        case .contrast:
            guard element.elementType == .staticText else { return false }
            return drawnByMacOS(element, app: app, window: window) || sampledElsewhere(element, app: app, window: window)
        case .sufficientElementDescription:
            // A SwiftUI menu button (`Menu`) is a pop-up with its title and no description, whatever its label or text;
            // VoiceOver reads the title. One without a title still fails.
            if element.elementType == .popUpButton { return !element.title.isEmpty }
            return element.elementType == .group && unnamedHost(element, app: app, window: window)
        default:
            return false
        }
    }

    /// Text whose colours macOS chooses, not the app.
    @MainActor private static func drawnByMacOS(_ element: XCUIElement, app: XCUIApplication, window: XCUIElement) -> Bool {
        // The titles macOS draws in title bars (dimmed in a window behind).
        let titles = Set(([window] + app.windows.allElementsBoundByIndex).map(\.title))
        if let value = element.value as? String, titles.contains(value) { return true }
        // Text in a sidebar (the list at the left edge of the window or of a sheet on it): macOS draws it vibrant over
        // the sidebar's material, which shows what is behind (the desktop picture, a VM's screen), so the sampled
        // contrast is that picture's (it passes or fails with it).
        let hosts = [window] + app.sheets.allElementsBoundByIndex
        let sidebars = hosts.compactMap { host in
            host.outlines.allElementsBoundByIndex.first { abs($0.frame.minX - host.frame.minX) < 24 }
        }
        if sidebars.contains(where: { $0.frame.contains(element.frame) }) { return true }
        // Text in a selected list row: macOS draws it white on the accent colour (its selection, not the app's colours;
        // about 3.6:1 against the 4.5:1 the audit asks of small text).
        let rows = window.outlineRows.allElementsBoundByIndex + window.cells.allElementsBoundByIndex
        let selectedRows = rows.filter(\.isSelected)
        return selectedRows.contains { $0.frame.contains(element.frame) }
    }

    /// Text whose pixels the audit takes from something else: audited where it is in front and in view.
    @MainActor private static func sampledElsewhere(_ element: XCUIElement, app: XCUIApplication, window: XCUIElement) -> Bool {
        let value = element.value as? String ?? ""
        let sameText = NSPredicate(format: "value == %@", value)
        // Text of a window behind this one (the library behind Settings) that it partly covers.
        if !value.isEmpty, !window.staticTexts.matching(sameText).firstMatch.exists { return true }
        // The window's own text while a sheet is open on it: macOS dims the window behind (the welcome over an empty
        // library). That text is audited with no sheet open.
        if !value.isEmpty, app.sheets.firstMatch.exists, !app.sheets.firstMatch.staticTexts.matching(sameText).firstMatch.exists {
            return true
        }
        // Window text under an open sheet, or a sheet's text scrolled out of its visible area: the audit samples what
        // covers it (the sheet, the buttons' bar).
        return app.sheets.allElementsBoundByIndex.contains { sheet in
            let inSheet = sheet.staticTexts.matching(sameText).firstMatch.exists
            if sheet.frame.intersects(element.frame) && !inSheet { return true }  // under it, even in part
            let scroll = sheet.scrollViews.firstMatch
            return inSheet && scroll.exists && !scroll.frame.contains(element.frame)
        }
    }

    /// An unnamed group that is not the app's to name: a list's section header row, or a window, sheet or column host.
    @MainActor private static func unnamedHost(_ element: XCUIElement, app: XCUIApplication, window: XCUIElement) -> Bool {
        // A list's section header: AppKit's empty row behind its title, a text of its own that VoiceOver reads (a
        // disabled row's height, with a text inside its frame).
        if !element.isEnabled, element.frame.height <= 24,
            (app.sheets.firstMatch.staticTexts.allElementsBoundByIndex + window.staticTexts.allElementsBoundByIndex)
                .contains(where: { element.frame.contains($0.frame) && !$0.label.isEmpty })
        {
            return true
        }
        if app.sheets.allElementsBoundByIndex.contains(where: { $0.frame == element.frame }) { return true }
        // A host in this window or in another one of the app's (the library behind Settings): a window or column host
        // spans the window's height; a content host spans its width down to its bottom edge, below a toolbar.
        return ([window] + app.windows.allElementsBoundByIndex).contains { host in
            (element.frame.minY == host.frame.minY && element.frame.height == host.frame.height)
                || (element.frame.width == host.frame.width && element.frame.maxY == host.frame.maxY
                    && element.frame.height >= host.frame.height * 0.75)
        }
    }
}
