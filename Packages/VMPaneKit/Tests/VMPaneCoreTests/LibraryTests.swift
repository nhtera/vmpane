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

@Test func aDeletedOrDamagedVMIsExplainedInWordsAndCanBeRemoved() throws {
    try withTempDirectory { dir in
        let library = VMLibrary(paths: VMPanePaths(root: dir.appendingPathComponent("support")))
        let elsewhere = dir.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let gone = try VMBundle.create(at: elsewhere.appendingPathComponent("Gone.vmpane"), config: makeConfig(name: "Gone"))
        let damaged = try VMBundle.create(at: elsewhere.appendingPathComponent("Damaged.vmpane"), config: makeConfig(name: "Damaged"))
        try library.register(gone)
        try library.register(damaged)
        try FileManager.default.removeItem(at: gone.url)
        try Data("{".utf8).write(to: damaged.configURL)

        let items = try library.items()
        let problems = Dictionary(uniqueKeysWithValues: items.map { ($0.bundle.url.lastPathComponent, $0.error) })
        #expect(problems["Gone.vmpane"]??.hasPrefix("Not found.") == true)
        #expect(problems["Damaged.vmpane"]??.contains("damaged") == true)

        let goneID = try #require(library.readIndex().bundles.first { $0.path.hasSuffix("Gone.vmpane") }?.id)
        try library.unregister(id: goneID)
        #expect(try library.items().map(\.bundle.url.lastPathComponent) == ["Damaged.vmpane"])
    }
}

@Test func libraryProblemsReadAsSentences() {
    let here = URL(fileURLWithPath: "/")
    #expect(VMLibrary.problem(ConfigError.newerSchema(found: 9, supported: 1), at: here).contains("newer version of VMPane"))
    #expect(VMLibrary.problem(BundleError.symlink, at: here).contains("symbolic link"))
    #expect(!VMLibrary.problem(BundleError.notABundle, at: here).contains("notABundle"))
}

/// The app lists a VM found in the default folder; its helper then opens the same bundle through another spelling of
/// the path (/tmp vs /private/tmp) and adopts it: the VM keeps its identity.
@Test func aVMFoundInTheDefaultFolderKeepsItsIdentityWhenItsHelperAdoptsIt() throws {
    let root = URL(fileURLWithPath: "/tmp/vp-found-\(UUID().uuidString.prefix(8))")
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = VMPanePaths(root: root)
    let library = VMLibrary(paths: paths)
    try FileManager.default.createDirectory(at: paths.defaultLibrary, withIntermediateDirectories: true)
    let folder = paths.defaultLibrary
    let a = try VMBundle.create(at: folder.appendingPathComponent("A.vmpane"), config: makeConfig(name: "A", mac: "52:54:00:00:00:0a"))
    _ = try VMBundle.create(at: folder.appendingPathComponent("B.vmpane"), config: makeConfig(name: "B", mac: "52:54:00:00:00:0b"))
    let id = try ConfigStore.load(a).id
    #expect(try library.items().count == 2)  // the app's listing indexes both

    let opened = try VMBundle.open(URL(fileURLWithPath: root.path).appendingPathComponent("VMs/A.vmpane"))
    let lock = try #require(try opened.tryLock(retryingFor: 5))
    defer { lock.release() }
    let adopted = try library.adopt(holding: lock)
    #expect(!adopted.regenerated)
    #expect(adopted.config.id == id)
    #expect(try library.readIndex().bundles.count == 2)
}

/// A Finder copy keeps the original's id until its helper adopts it; until then it is listed under an id of its own
/// (stable across listings), so no two listed VMs share one.
@Test func anUnadoptedCopyIsListedUnderAnIDOfItsOwn() throws {
    try withTempDirectory { dir in
        let paths = VMPanePaths(root: dir.appendingPathComponent("support"))
        let library = VMLibrary(paths: paths)
        try FileManager.default.createDirectory(at: paths.defaultLibrary, withIntermediateDirectories: true)
        let original = try VMBundle.create(at: paths.defaultLibrary.appendingPathComponent("B.vmpane"), config: makeConfig(name: "B"))
        try library.register(original)
        try FileManager.default.copyItem(at: original.url, to: paths.defaultLibrary.appendingPathComponent("B copy.vmpane"))
        let items = try library.items()
        #expect(items.count == 2)
        #expect(Set(items.map(\.id)).count == 2)
        #expect(items.first { $0.bundle.url.lastPathComponent == "B.vmpane" }?.id == (try ConfigStore.load(original).id))
        #expect(try library.items().map(\.id) == items.map(\.id))
    }
}

@Test func systemErrorsReadAsSentences() {
    let vz = NSError(
        domain: "VZErrorDomain", code: 3,
        userInfo: [
            NSLocalizedDescriptionKey: "Invalid virtual machine state.",
            NSLocalizedFailureReasonErrorKey: "Virtual machine state “saving” is invalid for saving.",
        ])
    #expect(ErrorText.readable(vz) == "Invalid virtual machine state. Virtual machine state “saving” is invalid for saving.")
    #expect(ErrorText.readable(BundleError.symlink) == String(describing: BundleError.symlink))
    let posix = NSError(domain: NSPOSIXErrorDomain, code: Int(EBUSY))
    #expect(!ErrorText.readable(posix).contains("Resource busy Resource busy"))
}
