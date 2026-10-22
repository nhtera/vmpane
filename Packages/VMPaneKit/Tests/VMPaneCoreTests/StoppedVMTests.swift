import Foundation
import Testing

@testable import VMPaneCore

private struct Library {
    let ops: LibraryOps
    let bundle: VMBundle
    let root: URL
}

private func library() throws -> Library {
    let root = URL(fileURLWithPath: "/tmp/vp-stopped-\(UUID().uuidString.prefix(8))", isDirectory: true)
    let ops = LibraryOps(library: VMLibrary(paths: VMPanePaths(root: root.appendingPathComponent("s"))), identity: .ui)
    return Library(ops: ops, bundle: try ops.create(name: "V", os: .linux, diskGiB: 2), root: root)
}

/// The inspector changes a stopped VM's hardware with no helper: saved, the disk grown, never shrunk.
@Test func aStoppedVMsHardwareChangesWithoutAHelper() throws {
    let made = try library()
    let (ops, bundle, root) = (made.ops, made.bundle, made.root)
    defer { try? FileManager.default.removeItem(at: root) }
    let config = try ops.updateStopped(bundle) { settings in
        settings.cpuCount = 3
        settings.memoryMiB = 6144
        settings.diskGiB = 4
        settings.displayWidth = 1920
        settings.displayHeight = 1200
    }
    let saved = try ConfigStore.load(bundle)
    #expect(saved == config && saved.cpu.count == 3 && saved.memory.mib == 6144 && saved.disks[0].sizeGiB == 4)
    #expect(saved.display.widthPx == 1920 && saved.display.heightPx == 1200)
    let disk = try bundle.fileURL(relativePath: saved.disks[0].file)
    #expect(try disk.resourceValues(forKeys: [.fileSizeKey]).fileSize == 4 << 30)
    #expect(throws: StoppedSettings.Problem.diskShrink) { try ops.updateStopped(bundle) { $0.diskGiB = 1 } }
    #expect(throws: StoppedSettings.Problem.tooSmall) { try ops.updateStopped(bundle) { $0.memoryMiB = 512 } }
    // A helper holds the VM: its settings go through the helper instead.
    let lock = try #require(try bundle.tryLock(retryingFor: 5))
    #expect(throws: LibraryOps.VMRunning.self) { try ops.updateStopped(bundle) { $0.cpuCount = 1 } }
    lock.release()
    // Only the app.
    let agent = LibraryOps(library: ops.library, identity: .automated)
    #expect(throws: LibraryOps.PolicyDenied.self) { try agent.updateStopped(bundle) { $0.cpuCount = 1 } }
}

@Test func aStoppedVMsSnapshotsAreListedRenamedAndDeleted() throws {
    let made = try library()
    let (ops, bundle, root) = (made.ops, made.bundle, made.root)
    defer { try? FileManager.default.removeItem(at: root) }
    let lock = try #require(try bundle.tryLock(retryingFor: 5))
    let context = SnapshotContext(deviceSetHash: "h", hostBuild: "b", backendVersion: "v")
    let first = try SnapshotStore(lock: lock).create(
        name: "First", kind: .disk, origin: .user, context: context, now: Date(timeIntervalSince1970: 1000),
        availableSpace: { _ in 1 << 40 })
    let second = try SnapshotStore(lock: lock).create(
        name: "Second", kind: .disk, origin: .user, context: context, now: Date(timeIntervalSince1970: 2000),
        availableSpace: { _ in 1 << 40 })
    lock.release()
    #expect(try ops.snapshots(of: bundle).map(\.id) == [second.id, first.id], "newest first")
    try ops.renameSnapshot(first.id, to: "Before the upgrade", in: bundle)
    #expect(try ops.snapshots(of: bundle).last?.name == "Before the upgrade")
    try ops.deleteSnapshot(second.id, in: bundle)
    #expect(try ops.snapshots(of: bundle).map(\.id) == [first.id])
    try ops.restoreSnapshot(first.id, in: bundle)
    #expect(throws: SnapshotError.notFound(second.id)) { try ops.renameSnapshot(second.id, to: "x", in: bundle) }
}
