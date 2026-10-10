import Foundation
import Testing

@testable import VMPaneHost

@Test func downloadCandidatesAreWindowsArm64ISONames() {
    #expect(DownloadWatcher.isCandidateName("Win11_25H2_English_Arm64.iso"))
    #expect(DownloadWatcher.isCandidateName("Windows11_Client_arm64_en-us_26300_9457.iso"))
    #expect(!DownloadWatcher.isCandidateName("Win11_25H2_English_x64.iso"))
    #expect(!DownloadWatcher.isCandidateName("Win11_25H2_English_Arm64.iso.download"))
    #expect(!DownloadWatcher.isCandidateName("Win11_25H2_English_Arm64.iso.crdownload"))
    #expect(!DownloadWatcher.isCandidateName("debian-13-arm64-netinst.iso"))
}

@Test func aNewDownloadIsReportedOnceItStopsGrowing() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vp-dl-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try Data("old".utf8).write(to: dir.appendingPathComponent("Win11_24H2_English_Arm64.iso"))
    let watcher = DownloadWatcher(directory: dir, interval: .milliseconds(20), stableChecks: 3)
    let existing = watcher.snapshot()
    #expect(existing == ["Win11_24H2_English_Arm64.iso"])

    let found = Task { await watcher.waitForDownload(ignoring: existing) }
    // The browser writes to a partial name, grows it, then renames it.
    let partial = dir.appendingPathComponent("Win11_25H2_English_Arm64.iso.crdownload")
    try Data(count: 10).write(to: partial)
    try await Task.sleep(for: .milliseconds(100))
    let final = dir.appendingPathComponent("Win11_25H2_English_Arm64.iso")
    try FileManager.default.moveItem(at: partial, to: final)
    #expect(await found.value?.lastPathComponent == "Win11_25H2_English_Arm64.iso")
}

@Test func watchingStopsWhenCancelled() async throws {
    let watcher = DownloadWatcher(directory: FileManager.default.temporaryDirectory, interval: .milliseconds(20))
    let waiting = Task { await watcher.waitForDownload(ignoring: watcher.snapshot()) }
    waiting.cancel()
    #expect(await waiting.value == nil)
}
