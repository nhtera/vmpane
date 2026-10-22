import Foundation
import Testing
import VMPaneControl
import VMPaneCore

@testable import VMPaneUI

/// A bundle a quit left half made (its `.creating` marker) is a problem row to delete, never a VM ready to start.
@Test @MainActor func aHalfMadeBundleIsShownAsUnfinished() async throws {
    let fixture = try makeStore(FakeLinks())
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let half = try fixture.ops.create(name: "Half", os: .linux, diskGiB: 1, unfinished: true)
    _ = try fixture.ops.create(name: "Whole", os: .linux, diskGiB: 1)
    await fixture.store.reload()
    #expect(fixture.store.rows.first { $0.name == "Half" }?.error?.contains("before this VM was finished") == true)
    #expect(fixture.store.rows.first { $0.name == "Whole" }?.error == nil)
    try half.markFinished()
    await fixture.store.reload()
    #expect(fixture.store.rows.allSatisfy { $0.error == nil })
}

/// Create closes the sheet at once: the library lists the VM being made, then the VM, which starts; a failed one
/// stays with its reason for Retry or Remove and leaves no bundle.
@Test @MainActor func createsRunInTheBackground() async throws {
    let started = LockedFlag()
    let fixture = try makeStore(FakeLinks()) { _, _ in started.set() }
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let wizard = WizardModel(host: .init(cores: 8, memoryGiB: 16), existingNames: [])
    wizard.use(URL(fileURLWithPath: "/tmp/UniversalMac.ipsw"), kind: .macRestoreImage)
    fixture.store.create(try #require(wizard.request()))
    #expect(fixture.store.creations.count == 1)
    #expect(await eventually { fixture.store.creations.isEmpty && fixture.store.rows.count == 1 })
    #expect(await eventually { started.value }, "the new VM starts (its install)")

    let junk = fixture.root.appendingPathComponent("junk.iso")
    try Data("not an iso".utf8).write(to: junk)
    wizard.use(junk, kind: .linuxISO)
    wizard.name = "Broken"
    fixture.store.create(try #require(wizard.request()))
    #expect(await eventually { fixture.store.creations.first?.failure != nil })
    #expect(try fixture.ops.library.items().count == 1, "the failed create left no bundle")
    let id = try #require(fixture.store.creations.first?.id)
    fixture.store.retryCreation(id)
    #expect(await eventually { fixture.store.creations.first?.failure != nil })
    fixture.store.forgetCreation(id)
    #expect(fixture.store.creations.isEmpty)
}

/// A running VM's install stage shows on its row (also after the app relaunched: the helper replays it).
@Test @MainActor func aRowShowsItsInstallStage() async throws {
    let links = FakeLinks()
    let fixture = try makeStore(links)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let bundle = try fixture.ops.create(name: "Win", os: .windows, diskGiB: 64)
    let id = try ConfigStore.load(bundle).id
    links.run(id, in: .running)
    await fixture.store.reload()
    links.emitInstall(id, ["phase": "install", "percent": 30, "message": "Windows Setup is installing"])
    #expect(await eventually { fixture.store.row(id)?.install?.message == "Windows Setup is installing" })
    #expect(fixture.store.row(id)?.install?.isActive == true)
    await fixture.store.reload()
    #expect(fixture.store.row(id)?.install?.percent == 30, "a reload keeps what the helper said")
}

/// While a create here prepares its VM, the library lists the creation, not a VM that looks ready to start.
@Test @MainActor func aVMBeingPreparedIsNotListedYet() async throws {
    let fixture = try makeStore(FakeLinks())
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let bundle = try fixture.ops.create(name: "Busy", os: .linux, diskGiB: 1, unfinished: true)
    fixture.store.creations = [LibraryStore.Creation(id: UUID(), name: "Busy", os: .linux)]
    await fixture.store.reload()
    #expect(fixture.store.rows.isEmpty, "not yet said which bundle: known by its name")
    fixture.store.creations[0].bundle = bundle.url
    await fixture.store.reload()
    #expect(fixture.store.rows.isEmpty)
    fixture.store.creations = []
    await fixture.store.reload()
    #expect(fixture.store.rows.first?.error?.contains("before this VM was finished") == true, "left by a quit")
}
