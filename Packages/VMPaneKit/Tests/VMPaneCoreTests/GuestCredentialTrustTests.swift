import Foundation
import Testing

@testable import VMPaneCore

/// A minimal app bundle at `url` with bundle id `id`.
private func makeApp(_ url: URL, id: String) throws {
    try FileManager.default.createDirectory(at: url.appendingPathComponent("Contents"), withIntermediateDirectories: true)
    let plist: [String: Any] = ["CFBundleIdentifier": id, "CFBundlePackageType": "APPL", "CFBundleExecutable": "x"]
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        .write(to: url.appendingPathComponent("Contents/Info.plist"))
}

/// Written by the app (a new VM): the Keychain item trusts the app and its VM helper; the writer is not listed twice.
@Test func theAppTrustsItselfAndItsHelper() throws {
    let root = URL(fileURLWithPath: "/tmp/vp-trust-\(UUID().uuidString.prefix(8))", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let app = root.appendingPathComponent("VMPane.app", isDirectory: true)
    try makeApp(app, id: VMPane.SigningIdentifier.app)
    try makeApp(app.appendingPathComponent("Contents/Helpers/VMPaneVM.app"), id: VMPane.SigningIdentifier.helper)
    let bundle = try #require(Bundle(url: app))
    #expect(
        KeychainGuestCredentials.trustedApps(main: bundle).map(\.lastPathComponent) == ["VMPane.app", "VMPaneVM.app"])
}

/// Written by a VM's helper (its settings), which runs from a runtime copy: the writer is trusted, and VMPane too when
/// LaunchServices knows it, so the app's Copy Password can read what the helper saved.
@Test func aHelperTrustsItselfAndVMPaneWhenItIsKnown() throws {
    let root = URL(fileURLWithPath: "/tmp/vp-trust-\(UUID().uuidString.prefix(8))", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let copy = root.appendingPathComponent("VMPaneVM.app", isDirectory: true)
    try makeApp(copy, id: VMPane.SigningIdentifier.helper)
    let trusted = KeychainGuestCredentials.trustedApps(main: try #require(Bundle(url: copy)))
    #expect(trusted.first?.standardizedFileURL == copy.standardizedFileURL)
    #expect(trusted.dropFirst().allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
}
