import Foundation
import Testing
import VMPaneControl
import VMPaneCore

@testable import VMPaneUI

// A VM's helper from before an app update (issue #12).

let oldRuntime = "1.0.0-beta.11-q0a1b2c3d-h1a2b3c4d"
let newRuntime = "1.0.0-beta.12-q0a1b2c3d-h5e6f7a8b"

/// A store whose VM "Old" (`id`) has a live helper (`process`, with its pid record) from `oldRuntime`.
@MainActor
struct OldHelper {
    let fixture: Fixture
    let id: UUID
    let process: Process
}

@MainActor
func storeWithOldHelper(_ links: FakeLinks, state: VMRunState, launched: LockedFlag) throws -> OldHelper {
    let fixture = try makeStore(links) { bundle, _ in
        launched.set()
        let id = try ConfigStore.load(bundle).id
        Task {
            try? await Task.sleep(for: .milliseconds(100))
            links.run(id, in: .stopped)
        }
    }
    fixture.store.currentRuntime = { newRuntime }
    let bundle = try fixture.ops.create(name: "Old", os: .linux, diskGiB: 8)
    let id = try ConfigStore.load(bundle).id
    let old = Process()
    old.executableURL = URL(fileURLWithPath: "/bin/sleep")
    old.arguments = ["60"]
    try old.run()
    let record = try #require(ProcessRecord.current(pid: old.processIdentifier))
    try RunFiles(paths: VMPanePaths(root: fixture.root), sid: ShortID(id))
        .writeHelper(HelperRecord(process: record, runtimeVersion: oldRuntime, bundlePath: bundle.url.path, vmId: id))
    links.answers[ControlMethod.vmInfo.rawValue] = ["state": .string(state.rawValue)]
    links.onCall = { method in
        guard method == ControlMethod.helperShutdown.rawValue else { return }
        old.terminate()
        old.waitUntilExit()
        links.end(id)
    }
    links.run(id, in: state)
    return OldHelper(fixture: fixture, id: id, process: old)
}

@Test @MainActor func startingAStoppedVMWhoseHelperIsFromAnOlderRuntimeLaunchesANewOne() async throws {
    let links = FakeLinks()
    let launched = LockedFlag()
    let helper = try storeWithOldHelper(links, state: .stopped, launched: launched)
    let (fixture, id, old) = (helper.fixture, helper.id, helper.process)
    let store = fixture.store
    defer {
        if old.isRunning { old.terminate() }
        try? FileManager.default.removeItem(at: fixture.root)
    }
    await store.reload()
    #expect(await eventually { store.row(id)?.state == .stopped && store.row(id)?.outdatedRuntime == true })
    #expect(store.row(id)?.restartToUpdate == false)  // stopped: the next start takes the update
    await store.perform(.start(headless: false), on: id)
    #expect(store.lastError == nil)
    #expect(launched.value)
    #expect(links.methods == [ControlMethod.vmInfo.rawValue, ControlMethod.helperShutdown.rawValue, "vm.start"])
    #expect(store.row(id)?.outdatedRuntime == false)
}

@Test @MainActor func aRunningOrSuspendedVMKeepsItsOlderHelper() async throws {
    for state in [VMRunState.running, .stopped] {
        let links = FakeLinks()
        let launched = LockedFlag()
        let helper = try storeWithOldHelper(links, state: state, launched: launched)
        let (fixture, id, old) = (helper.fixture, helper.id, helper.process)
        let store = fixture.store
        defer {
            old.terminate()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        // The stopped one is suspended: its saved memory belongs to the helper that saved it.
        if state == .stopped { links.answers[ControlMethod.vmInfo.rawValue] = ["state": "stopped", "suspended": true] }
        await store.reload()
        #expect(await eventually { store.row(id)?.state == state && store.row(id)?.outdatedRuntime == true })
        #expect(store.row(id)?.restartToUpdate == (state == .running))
        await store.perform(.start(headless: false), on: id)
        #expect(!launched.value)
        #expect(!links.methods.contains(ControlMethod.helperShutdown.rawValue))
        #expect(old.isRunning)
    }
}

@Test @MainActor func withoutItsRuntimeTheStoreKeepsEveryHelper() async throws {
    let links = FakeLinks()
    let launched = LockedFlag()
    let helper = try storeWithOldHelper(links, state: .stopped, launched: launched)
    let (fixture, id, old) = (helper.fixture, helper.id, helper.process)
    let store = fixture.store
    defer {
        old.terminate()
        try? FileManager.default.removeItem(at: fixture.root)
    }
    store.currentRuntime = { nil }
    await store.reload()
    #expect(await eventually { store.row(id)?.state == .stopped })
    #expect(store.row(id)?.outdatedRuntime == false)
    await store.perform(.start(headless: false), on: id)
    #expect(links.methods == ["vm.start"])
    #expect(!launched.value)
}

@Test func onlyAHelperFromAnotherRuntimeCopyIsOutdated() {
    #expect(RuntimeStore.isOutdated(oldRuntime, current: newRuntime))
    #expect(!RuntimeStore.isOutdated(newRuntime, current: newRuntime))
    #expect(!RuntimeStore.isOutdated(oldRuntime, current: nil))
    // Started from the app bundle (development): the bare app version, never outdated.
    #expect(!RuntimeStore.isOutdated("1.0.0-beta.11", current: newRuntime))
    #expect(!RuntimeStore.isOutdated("", current: newRuntime))
}

/// A VM on a helper from before an update says a restart takes the update, only while it runs (a stopped one gets
/// a new helper on its next start).
@MainActor @Test func aRunningVMOnAnOldRuntimeAsksForARestart() {
    var row = LibraryStore.Row(id: UUID(), name: "Windows 11", os: .windows, bundleURL: URL(fileURLWithPath: "/tmp/w.vmpane"))
    row.outdatedRuntime = true
    row.state = .running
    #expect(row.restartToUpdate)
    row.state = .stopped
    #expect(!row.restartToUpdate)
    row.outdatedRuntime = false
    row.state = .running
    #expect(!row.restartToUpdate)
}
