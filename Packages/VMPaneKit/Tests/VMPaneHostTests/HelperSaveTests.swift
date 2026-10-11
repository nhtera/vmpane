import Foundation
import Testing
import VMPaneControl
import VMPaneCore

@testable import VMPaneHost

/// The backend's power-off announces "stopped" before the suspend is saved; once it is, the state is announced
/// again, so the app shows the VM as suspended (it checks then).
@Test func aSuspendIsAnnouncedOnceItsStateIsSaved() async throws {
    let helper = try await Harness.make()
    helper.backend.announcesStopOnSuspend = true
    _ = try await helper.client.call("events.subscribe", params: ["topics": ["vm"]])
    let notes = NoteLog()
    let reader = Task { for await note in helper.client.notifications { notes.append(note.params) } }
    _ = try await helper.client.call("vm.start")
    _ = try await helper.client.call("vm.suspend")
    try await Task.sleep(for: .milliseconds(300))
    reader.cancel()
    let last = try #require(notes.all.last)
    #expect(last?["state"] == "stopped")
    #expect(last?["reason"] == "suspended")
    await helper.tearDown()
}

final class NoteLog: @unchecked Sendable {
    private let lock = NSLock()
    private var notes: [JSONValue?] = []
    func append(_ note: JSONValue?) { lock.withLock { notes.append(note) } }
    var all: [JSONValue?] { lock.withLock { notes } }
}

/// Two live snapshots at once (a double click, an agent and the user): taken one after the other, both kept.
@Test func snapshotsAskedForAtOnceAreTakenInTurn() async throws {
    let helper = try await Harness.make()
    helper.backend.saveDelay = .milliseconds(300)
    _ = try await helper.client.call("vm.start")
    async let first = helper.client.call("vm.snapshot.create", params: ["name": "a", "kind": "live"])
    try await Task.sleep(for: .milliseconds(100))
    let second = try await helper.client.call("vm.snapshot.create", params: ["name": "b", "kind": "live"])
    #expect(try await first["name"] == "a")
    #expect(second["name"] == "b")
    await helper.tearDown()
}
