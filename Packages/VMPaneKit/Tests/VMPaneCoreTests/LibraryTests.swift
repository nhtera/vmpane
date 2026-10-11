import Foundation
import Testing

@testable import VMPaneCore

@Test func libraryRegistersResolvesAndFollowsMoves() throws {
    try withTempDirectory { dir in
        let library = VMLibrary(paths: VMPanePaths(root: dir.appendingPathComponent("support")))
        let elsewhere = dir.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let bundle = try VMBundle.create(at: elsewhere.appendingPathComponent("A.vmpane"), config: makeConfig(name: "A"))
        try library.register(bundle)
        #expect(try library.items().map(\.config?.name) == ["A"])

        let moved = elsewhere.appendingPathComponent("Renamed.vmpane")
        try FileManager.default.moveItem(at: bundle.url, to: moved)
        let items = try library.items()
        #expect(items.count == 1)
        #expect(items[0].bundle.url.lastPathComponent == "Renamed.vmpane")
        #expect(try library.readIndex().bundles[0].path.hasSuffix("Renamed.vmpane"))
    }
}

@Test func libraryFindsBundlesInTheDefaultDirectory() throws {
    try withTempDirectory { dir in
        let paths = VMPanePaths(root: dir.appendingPathComponent("support"))
        let library = VMLibrary(paths: paths)
        try FileManager.default.createDirectory(at: paths.defaultLibrary, withIntermediateDirectories: true)
        _ = try VMBundle.create(at: paths.defaultLibrary.appendingPathComponent("Found.vmpane"), config: makeConfig(name: "Found"))
        #expect(try library.items().map(\.config?.name) == ["Found"])
        #expect(try library.readIndex().bundles.count == 1)
        #expect(try library.items().count == 1)  // not added twice
    }
}

@Test func finderCopyIsTheDuplicate() throws {
    try withTempDirectory { dir in
        let paths = VMPanePaths(root: dir.appendingPathComponent("support"))
        let library = VMLibrary(paths: paths)
        try FileManager.default.createDirectory(at: paths.defaultLibrary, withIntermediateDirectories: true)
        let original = try VMBundle.create(at: paths.defaultLibrary.appendingPathComponent("B.vmpane"), config: makeConfig(name: "B"))
        try library.register(original)
        let copy = paths.defaultLibrary.appendingPathComponent("B copy.vmpane")
        try FileManager.default.copyItem(at: original.url, to: copy)
        let conflicts = VMLibrary.identityConflicts(try library.items())
        #expect(conflicts == [.init(original: original.url, duplicate: try VMBundle.open(copy).url)])
    }
}

@Test func registeringAMACCloneGivesItANewIdentity() throws {
    try withTempDirectory { dir in
        let library = VMLibrary(paths: VMPanePaths(root: dir.appendingPathComponent("support")))
        let a = try VMBundle.create(at: dir.appendingPathComponent("A.vmpane"), config: makeConfig(name: "A", mac: "52:54:00:aa:bb:cc"))
        let b = try VMBundle.create(at: dir.appendingPathComponent("B.vmpane"), config: makeConfig(name: "B", mac: "52:54:00:AA:BB:CC"))
        try library.register(a)
        let before = try ConfigStore.load(b)
        try library.register(b)
        let after = try ConfigStore.load(b)
        #expect(after.network[0].macAddress != before.network[0].macAddress)
        #expect(after.id != before.id)
        #expect(try ConfigStore.load(a).network[0].macAddress == "52:54:00:aa:bb:cc")  // the original keeps its identity
        #expect(VMLibrary.identityConflicts(try library.items()).isEmpty)
        #expect(try library.readIndex().bundles.count == 2)
    }
}

@Test func registeringNeverEvictsAnotherVM() throws {
    try withTempDirectory { dir in
        let library = VMLibrary(paths: VMPanePaths(root: dir.appendingPathComponent("support")))
        let original = try VMBundle.create(at: dir.appendingPathComponent("O.vmpane"), config: makeConfig(name: "O"))
        try library.register(original)
        let copy = dir.appendingPathComponent("O copy.vmpane")
        try FileManager.default.copyItem(at: original.url, to: copy)
        try library.register(try VMBundle.open(copy))  // e.g. "Import…" of a Finder copy
        let index = try library.readIndex()
        #expect(index.bundles.count == 2)
        #expect(index.bundles.contains { $0.path == original.url.path && $0.id == (try? ConfigStore.load(original).id) })
        #expect(Set(index.bundles.map(\.id)).count == 2)
    }
}

/// The same bundle reached by another spelling of its path (/tmp is /private/tmp, a folder through a link) is not
/// a copy: it keeps its identity, and the library keeps one entry.
@Test func aBundleReachedThroughALinkKeepsItsIdentity() throws {
    let root = URL(fileURLWithPath: "/tmp/vp-link-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let library = VMLibrary(paths: VMPanePaths(root: root.appendingPathComponent("support")))
    let real = URL(fileURLWithPath: "/private" + root.path).appendingPathComponent("A.vmpane")
    let bundle = try VMBundle.create(at: real, config: makeConfig(name: "A"))
    let id = try ConfigStore.load(bundle).id
    try library.register(bundle)
    let viaLink = try VMBundle.open(root.appendingPathComponent("A.vmpane"))
    #expect(viaLink.url.path != bundle.url.path)
    let lock = try #require(try viaLink.tryLock(retryingFor: 5))
    defer { lock.release() }
    let adopted = try library.adopt(holding: lock)
    #expect(!adopted.regenerated && adopted.config.id == id)
    #expect(try library.readIndex().bundles.count == 1)
}
