import Foundation
import Testing

@testable import VMPaneCore

private func makeLibrary(_ dir: URL) -> VMLibrary {
    VMLibrary(paths: VMPanePaths(root: dir.appendingPathComponent("support")))
}

@Test func appCreatesClonesAndDeletes() throws {
    try withTempDirectory { dir in
        let library = makeLibrary(dir)
        let ops = LibraryOps(library: library, identity: .ui)
        let vm = try ops.create(name: "Dev/Box", os: .linux, diskGiB: 16)
        #expect(vm.url.lastPathComponent == "Dev-Box.vmpane")
        #expect(try DiskImage.logicalSize(vm.fileURL(relativePath: "current/disk.img")) == 16 << 30)
        let clone = try ops.clone(vm, name: "Dev/Box")
        #expect(clone.url.lastPathComponent == "Dev-Box 2.vmpane")
        #expect(try ops.list().count == 2)

        let running = try #require(try vm.tryLock(retryingFor: 5))
        #expect(throws: LibraryOps.VMRunning()) { try ops.delete(vm) }
        running.release()
        try ops.delete(vm)
        #expect(try ops.list().map(\.bundle.url) == [clone.url])
    }
}

@Test func automatedClientsSeeOnlyObservableVMsAndCannotCreate() throws {
    try withTempDirectory { dir in
        let library = makeLibrary(dir)
        let app = LibraryOps(library: library, identity: .ui)
        let hidden = try app.create(name: "Hidden", os: .linux, diskGiB: 1)
        let visible = try app.create(name: "Visible", os: .linux, diskGiB: 1)
        let lock = try #require(try visible.tryLock(retryingFor: 5))
        var config = try ConfigStore.load(visible)
        config.mcp.policy = .observe
        // As the app saves it: tagged (an untagged level counts as off).
        let key = try #require(PolicyKeyFile(paths: library.paths).key(create: true))
        try ConfigStore.save(PolicyIntegrity.signed(config, key: key), holding: lock)
        lock.release()

        let agent = LibraryOps(library: library, identity: .automated).recordingInVMLogs(label: "cli", kind: "mcp", session: "s1")
        #expect(try agent.list().map(\.bundle.url) == [visible.url])
        #expect(throws: LibraryOps.PolicyDenied.self) { try agent.create(name: "X", os: .linux, diskGiB: 1) }
        #expect(throws: LibraryOps.PolicyDenied.self) { try agent.delete(hidden) }
        // The refusal is in the VM's own record.
        let recorded = AuditLog(bundle: hidden).recent(limit: 5)
        #expect(recorded.map(\.method) == ["vm.delete"])
        #expect(recorded.first?.result == "denied" && recorded.first?.session == "s1" && recorded.first?.kind == "mcp")
        let human = LibraryOps(library: library, identity: .operator)
        #expect(try human.list().count == 2)
        #expect(throws: LibraryOps.PolicyDenied.self) { try human.create(name: "X", os: .linux, diskGiB: 1) }  // uiOnly
    }
}

/// A clone keeps the agent policy the app set, and not one edited by hand.
@Test func clonesKeepOnlyAPolicyThatChecksOut() throws {
    try withTempDirectory { dir in
        let library = makeLibrary(dir)
        let app = LibraryOps(library: library, identity: .ui)
        let key = try #require(PolicyKeyFile(paths: library.paths).key(create: true))
        func make(_ name: String, signed: Bool) throws -> VMBundle {
            let vm = try app.create(name: name, os: .linux, diskGiB: 1)
            let lock = try #require(try vm.tryLock(retryingFor: 5))
            var config = try ConfigStore.load(vm)
            config.mcp.policy = .exec
            try ConfigStore.save(signed ? PolicyIntegrity.signed(config, key: key) : config, holding: lock)
            lock.release()
            return vm
        }
        let tagged = try ConfigStore.load(try app.clone(try make("Set", signed: true), name: "Set copy"))
        #expect(app.policy(tagged).level == .exec && !app.policy(tagged).tampered)
        let edited = try ConfigStore.load(try app.clone(try make("Edited", signed: false), name: "Edited copy"))
        #expect(app.policy(edited).level == .off && app.policy(edited).tampered)
    }
}
