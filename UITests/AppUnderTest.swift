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
        let titleBarButtons = window.buttons.matching(NSPredicate(format: "identifier BEGINSWITH '_XCUI:'"))
        func excuse(_ issue: XCUIAccessibilityAuditIssue) -> Bool {
            // SwiftUI's bridged title (a 14×16 group at the title bar's left) is listed in the content but names the
            // window as its parent; the audit cannot resolve it to an element. Any other issue needs its element.
            guard let element = issue.element else { return issue.auditType == .parentChild }
            if !window.frame.intersects(element.frame) { return true }  // the menu bar or another window
            // SwiftUI pop-ups have AXPress (an Accessibility dump of the VM settings shows it on every one), yet the audit
            // reports one of them (Resolution) as missing its action, also once the sheet has settled.
            if issue.auditType == .action, element.elementType == .popUpButton { return true }
            if issue.auditType == .parentChild {
                return titleBarButtons.allElementsBoundByIndex.contains { $0.frame.contains(element.frame) }
            }
            if issue.auditType == .contrast {
                // The titles macOS draws in title bars (dimmed in a window behind); or window text under an open sheet, where the audit samples
                // the sheet's pixels instead of the text's.
                let titles = Set(([window] + app.windows.allElementsBoundByIndex).map(\.title))
                if element.elementType == .staticText, let value = element.value as? String, titles.contains(value) { return true }
                // Or text of a window behind this one (the library behind Settings) that it partly covers: the audit
                // samples this window's pixels. That text is audited when its own window is in front.
                if element.elementType == .staticText, let value = element.value as? String,
                    !window.staticTexts.matching(NSPredicate(format: "value == %@", value)).firstMatch.exists
                {
                    return true
                }
                // Or a sheet's text scrolled out of its visible area: the audit samples what covers it (the buttons' bar).
                return app.sheets.allElementsBoundByIndex.contains { sheet in
                    let sameText = NSPredicate(format: "value == %@", element.value as? String ?? "")
                    let inSheet = sheet.staticTexts.matching(sameText).firstMatch.exists
                    if sheet.frame.intersects(element.frame) && !inSheet { return true }  // under it, even in part
                    let scroll = sheet.scrollViews.firstMatch
                    return inSheet && scroll.exists && !scroll.frame.contains(element.frame)
                }
            }
            guard issue.auditType == .sufficientElementDescription, element.elementType == .group else { return false }
            let sheetHost = app.sheets.allElementsBoundByIndex.contains { $0.frame == element.frame }
            // A host in this window or in another one of the app's (the library behind Settings): a window or column
            // host spans the window's height; a content host spans its width down to its bottom edge, below a toolbar.
            let windowHost = ([window] + app.windows.allElementsBoundByIndex).contains { host in
                (element.frame.minY == host.frame.minY && element.frame.height == host.frame.height)
                    || (element.frame.width == host.frame.width && element.frame.maxY == host.frame.maxY
                        && element.frame.height >= host.frame.height * 0.75)
            }
            return sheetHost || windowHost
        }
        try app.performAccessibilityAudit(for: .all) { issue in
            let excused = excuse(issue)
            if !excused {
                print("audit issue: \(issue.compactDescription) on \(issue.element?.debugDescription.prefix(300) ?? "no element")")
            }
            return excused
        }
    }
}
