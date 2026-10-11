import CryptoKit
import Foundation
import Testing

@testable import VMPaneCore

private func config(_ level: PolicyLevel) -> VMConfigV1 {
    var config = VMConfigV1(VMConfigFields.new(name: "V", os: .linux, macAddress: MachineIdentity.randomMACAddress()))
    config.mcp.policy = level
    return config
}

@Test func onlyATaggedPolicyCounts() {
    let key = SymmetricKey(size: .bits256)
    let tagged = PolicyIntegrity.signed(config(.exec), key: key)
    #expect(PolicyIntegrity.effective(tagged, key: key) == .init(level: .exec, tampered: false, clipboardAllowWithAgents: false))

    var edited = tagged
    edited.mcp.policy = .admin  // raised by hand in config.json
    #expect(PolicyIntegrity.effective(edited, key: key) == .init(level: .off, tampered: true, clipboardAllowWithAgents: false))
    var clipboard = tagged
    clipboard.clipboard.allowWithAgents = true
    #expect(PolicyIntegrity.effective(clipboard, key: key).tampered)
    var moved = tagged
    moved.id = UUID()  // copied onto another VM
    #expect(PolicyIntegrity.effective(moved, key: key).level == .off)
    #expect(PolicyIntegrity.effective(tagged, key: SymmetricKey(size: .bits256)).tampered, "another Mac's key")
    #expect(PolicyIntegrity.effective(tagged, key: nil).tampered, "no key")
    #expect(PolicyIntegrity.effective(config(.off), key: nil) == .init(level: .off, tampered: false, clipboardAllowWithAgents: false))
}

@Test func theKeyFileIsMadeOncePrivately() throws {
    let root = URL(fileURLWithPath: "/tmp/vp-key-\(UUID().uuidString.prefix(8))")
    defer { try? FileManager.default.removeItem(at: root) }
    let file = PolicyKeyFile(paths: VMPanePaths(root: root))
    #expect(file.key(create: false) == nil)
    let made = try #require(file.key(create: true))
    #expect(file.key(create: true) == made && file.key(create: false) == made)
    #expect(try FileManager.default.attributesOfItem(atPath: file.url.path)[.posixPermissions] as? Int == 0o600)
}

/// Agents (automated clients) see a VM only when its tagged policy is at least observe.
@Test func agentsSeeOnlyVMsWithAValidPolicy() throws {
    let root = URL(fileURLWithPath: "/tmp/vp-pol-\(UUID().uuidString.prefix(8))")
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = VMPanePaths(root: root)
    let ui = LibraryOps(library: VMLibrary(paths: paths), identity: .ui)
    let agent = LibraryOps(library: VMLibrary(paths: paths), identity: .automated)
    let bundle = try ui.create(name: "V", os: .linux, diskGiB: 1)
    #expect(try agent.list().isEmpty, "policy off")
    let key = try #require(PolicyKeyFile(paths: paths).key(create: true))
    let lock = try #require(try bundle.tryLock())
    var config = try ConfigStore.load(bundle)
    config.mcp.policy = .observe
    try ConfigStore.save(config, holding: lock)
    #expect(try agent.list().isEmpty, "raised by hand: no tag")
    try ConfigStore.save(PolicyIntegrity.signed(config, key: key), holding: lock)
    lock.release()
    #expect(try agent.list().map(\.id) == [config.id])
    #expect(try ui.list().count == 1)
}
