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
        try ConfigStore.save(config, holding: lock)
        lock.release()

        let agent = LibraryOps(library: library, identity: .automated)
        #expect(try agent.list().map(\.bundle.url) == [visible.url])
        #expect(throws: LibraryOps.PolicyDenied.self) { try agent.create(name: "X", os: .linux, diskGiB: 1) }
        #expect(throws: LibraryOps.PolicyDenied.self) { try agent.delete(hidden) }
        let human = LibraryOps(library: library, identity: .operator)
        #expect(try human.list().count == 2)
        #expect(throws: LibraryOps.PolicyDenied.self) { try human.create(name: "X", os: .linux, diskGiB: 1) }  // uiOnly
    }
}
