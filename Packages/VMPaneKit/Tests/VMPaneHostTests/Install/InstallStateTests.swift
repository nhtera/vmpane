import Foundation
import Testing
import VMPaneCore

@testable import VMPaneHost

@Test func installMovesOnlyForwardAndCountsBootAttempts() {
    let start = Date(timeIntervalSince1970: 1_000)
    var state = InstallState(now: start)
    state.advance(to: .firstBoot, now: start)
    #expect(state.phase == .firstBoot && state.attempts == 1)
    state.advance(to: .prepared)  // never back
    #expect(state.phase == .firstBoot)
    state.advance(to: .setupRunning, now: start.addingTimeInterval(60))
    state.advance(to: .firstBoot)  // a reboot during Setup never re-enters first boot (no key presses, no re-wipe)
    #expect(state.phase == .setupRunning && state.attempts == 1)
    state.advance(to: .toolsInstalled)  // skipping is allowed (the logon report can be missed)
    state.advance(to: .done)
    #expect(state.isFinished)
    state.end(.failed, reason: "late")  // a finished install stays finished
    #expect(state.phase == .done && state.reason == nil)
}

@Test func installEndsOnceWithItsFirstReasonAndTimesOutPerPhase() {
    let start = Date(timeIntervalSince1970: 1_000)
    var state = InstallState(now: start)
    #expect(!state.timedOut(now: start.addingTimeInterval(1_000_000)))  // waiting for the VM to start has no limit
    state.advance(to: .firstBoot, now: start)
    #expect(!state.timedOut(now: start.addingTimeInterval(170)) && state.timedOut(now: start.addingTimeInterval(190)))
    state.advance(to: .setupRunning, now: start.addingTimeInterval(200))
    #expect(!state.timedOut(now: start.addingTimeInterval(200 + 80 * 60)))
    state.end(.cancelled, reason: "user")
    state.end(.failed, reason: "later")
    #expect(state.phase == .cancelled && state.reason == "user")
    state.end(.done, reason: "x")  // done is not an end
    #expect(state.phase == .cancelled)
}

@Test func installStatePersistsInTheBundle() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vp-is-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let config = VMConfigV1(VMConfigFields.new(name: "W", os: .windows, macAddress: "52:54:00:00:00:04"))
    let bundle = try VMBundle.create(at: dir.appendingPathComponent("W.vmpane"), config: config)
    let lock = try #require(try bundle.tryLock(retryingFor: 5))
    #expect(InstallState.load(from: bundle) == nil)
    var state = InstallState(now: Date(timeIntervalSince1970: 5_000))
    state.advance(to: .firstBoot, now: Date(timeIntervalSince1970: 5_001))
    try state.save(holding: lock)
    #expect(InstallState.load(from: bundle) == state)
    #expect(try FileManager.default.attributesOfItem(atPath: InstallState.url(in: bundle).path)[.posixPermissions] as? Int == 0o600)
    InstallState.remove(from: bundle)
    #expect(InstallState.load(from: bundle) == nil)
}
