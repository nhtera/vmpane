import Foundation
import Testing
import VMPaneControl
import VMPaneCore

@testable import VMPaneUI

/// Helpers the test controls: a VM "runs" once `run` gives it a state stream.
final class FakeLinks: LiveVMLink, @unchecked Sendable {
    private let lock = NSLock()
    private var streams: [UUID: AsyncStream<VMRunState>.Continuation] = [:]
    private var pendingStreams: [UUID: AsyncStream<VMRunState>] = [:]
    struct Call {
        let vm: UUID
        let method: String
        let params: JSONValue?
    }

    private(set) var calls: [Call] = []
    var failure: RPCError?

    /// Makes `vmID` look like it has a helper in `state`.
    func run(_ vmID: UUID, in state: VMRunState) {
        let (stream, continuation) = AsyncStream.makeStream(of: VMRunState.self)
        continuation.yield(state)
        lock.withLock {
            streams[vmID] = continuation
            pendingStreams[vmID] = stream
        }
    }

    func emit(_ vmID: UUID, _ state: VMRunState) { _ = lock.withLock { streams[vmID] }?.yield(state) }

    /// The helper goes away.
    func end(_ vmID: UUID) { lock.withLock { streams.removeValue(forKey: vmID) }?.finish() }

    func watch(_ vmID: UUID) async -> AsyncStream<VMRunState>? {
        lock.withLock { pendingStreams.removeValue(forKey: vmID) }
    }

    func call(_ vmID: UUID, _ method: String, params: JSONValue?) async throws -> JSONValue {
        try lock.withLock {
            calls.append(Call(vm: vmID, method: method, params: params))
            if let failure { throw failure }
        }
        return [:]
    }

    var methods: [String] { lock.withLock { calls.map(\.method) } }
}

@MainActor
private struct Fixture {
    let store: LibraryStore
    let ops: LibraryOps
    let root: URL
}

@MainActor
private func makeStore(_ links: FakeLinks, launch: @escaping @Sendable (VMBundle, Bool) async throws -> Void = { _, _ in })
    throws -> Fixture
{
    let root = URL(fileURLWithPath: "/tmp/vp-ui-\(UUID().uuidString.prefix(8))", isDirectory: true)
    let library = VMLibrary(paths: VMPanePaths(root: root))
    let ops = LibraryOps(library: library, identity: .ui)
    return Fixture(store: LibraryStore(library: library, links: links, launch: launch), ops: ops, root: root)
}

/// Waits (up to 2 s) for `condition` on the main actor.
@MainActor
private func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
    for _ in 0..<100 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}

@Test @MainActor func reloadListsBundlesWithSizesAndNoHelper() async throws {
    let links = FakeLinks()
    let fixture = try makeStore(links)
    let (store, ops, root) = (fixture.store, fixture.ops, fixture.root)
    defer { try? FileManager.default.removeItem(at: root) }
    let linux = try ops.create(name: "Ubuntu", os: .linux, diskGiB: 8)
    _ = try ops.create(name: "Win", os: .windows, diskGiB: 64)
    await store.reload()
    #expect(store.rows.map(\.name).sorted() == ["Ubuntu", "Win"])
    let row = try #require(store.rows.first { $0.name == "Ubuntu" })
    #expect(row.os == .linux)
    #expect(row.bundleURL.standardizedFileURL == linux.url.standardizedFileURL)
    #expect(row.state == nil && !row.isRunning)
    #expect(row.diskBytes != nil)  // sparse: small, but measured
}

@Test @MainActor func helperEventsDriveTheRowState() async throws {
    let links = FakeLinks()
    let fixture = try makeStore(links)
    let (store, ops, root) = (fixture.store, fixture.ops, fixture.root)
    defer { try? FileManager.default.removeItem(at: root) }
    let bundle = try ops.create(name: "VM", os: .linux, diskGiB: 8)
    let id = try ConfigStore.load(bundle).id
    links.run(id, in: .running)
    await store.reload()
    #expect(await eventually { store.row(id)?.state == .running })
    links.emit(id, .paused)
    #expect(await eventually { store.row(id)?.state == .paused })
    links.end(id)
    #expect(await eventually { store.row(id)?.state == nil })
}

@Test @MainActor func actionsGoToTheHelperAndFailuresAreKept() async throws {
    let links = FakeLinks()
    let fixture = try makeStore(links)
    let (store, ops, root) = (fixture.store, fixture.ops, fixture.root)
    defer { try? FileManager.default.removeItem(at: root) }
    let id = try ConfigStore.load(try ops.create(name: "VM", os: .linux, diskGiB: 8)).id
    links.run(id, in: .running)
    await store.reload()
    await store.perform(.stop(force: false), on: id)
    await store.perform(.pause, on: id)
    #expect(links.methods == ["vm.stop", "vm.pause"])
    #expect(links.calls.first?.params == ["mode": "graceful"])
    links.failure = RPCError(.invalidState, "cannot resume while running")
    await store.perform(.resume, on: id)
    #expect(store.lastError == "cannot resume while running")
}

@Test @MainActor func startingAStoppedVMLaunchesItsHelperFirst() async throws {
    let links = FakeLinks()
    let launched = LockedFlag()
    let fixture = try makeStore(links) { bundle, headless in
        launched.set()
        #expect(!headless)
        // The launched helper starts listening a moment later.
        let id = try ConfigStore.load(bundle).id
        Task {
            try? await Task.sleep(for: .milliseconds(100))
            links.run(id, in: .stopped)
        }
    }
    let (store, ops, root) = (fixture.store, fixture.ops, fixture.root)
    defer { try? FileManager.default.removeItem(at: root) }
    let id = try ConfigStore.load(try ops.create(name: "VM", os: .linux, diskGiB: 8)).id
    await store.reload()
    await store.perform(.start(headless: false), on: id)
    #expect(launched.value)
    #expect(store.lastError == nil)
    #expect(links.methods == ["vm.start"])
}

final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set() { lock.withLock { flag = true } }
    var value: Bool { lock.withLock { flag } }
}

@Test @MainActor func clonesAndDeletesStoppedVMs() async throws {
    let links = FakeLinks()
    let fixture = try makeStore(links)
    let (store, ops, root) = (fixture.store, fixture.ops, fixture.root)
    defer { try? FileManager.default.removeItem(at: root) }
    let id = try ConfigStore.load(try ops.create(name: "Base", os: .linux, diskGiB: 8)).id
    await store.reload()
    await store.clone(id, name: "Base copy")
    #expect(store.rows.map(\.name).sorted() == ["Base", "Base copy"])
    await store.delete(id)
    #expect(store.rows.map(\.name) == ["Base copy"])
    #expect(store.lastError == nil)
}

@Test @MainActor func riskyShareFoldersAreFlagged() {
    let home = URL(fileURLWithPath: "/Users/someone")
    #expect(ShareWarning.reason(for: URL(fileURLWithPath: "/"), home: home) != nil)
    #expect(ShareWarning.reason(for: home, home: home) != nil)
    #expect(ShareWarning.reason(for: home.appendingPathComponent(".ssh"), home: home) != nil)
    #expect(ShareWarning.reason(for: home.appendingPathComponent("Library/Keychains"), home: home) != nil)
    #expect(ShareWarning.reason(for: home.appendingPathComponent("Projects/app"), home: home) == nil)
}
