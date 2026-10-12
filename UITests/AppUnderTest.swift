import XCTest

/// The app the UI tests drive: the one the itest scenario tests (`VMPANE_ITEST_APP`, e.g. a release candidate's,
/// mounted from its DMG), else the one this scheme built. xcodebuild hands `TEST_RUNNER_`-prefixed variables to the
/// tests without the prefix.
enum AppUnderTest {
    static var environment: [String: String] { ProcessInfo.processInfo.environment }

    /// The app, past the welcome, quit when `test` ends (one launched by URL would outlive it). A Release build's
    /// updater never asks whether to check for updates (Sparkle's question at the second launch).
    @MainActor static func app(for test: XCTestCase) -> XCUIApplication {
        let app = environment["VMPANE_ITEST_APP"].map { XCUIApplication(url: URL(fileURLWithPath: $0)) } ?? XCUIApplication()
        app.launchArguments += ["-onboarded", "YES", "-SUEnableAutomaticChecks", "NO"]
        test.addTeardownBlock { @MainActor in app.terminate() }
        return app
    }
}
