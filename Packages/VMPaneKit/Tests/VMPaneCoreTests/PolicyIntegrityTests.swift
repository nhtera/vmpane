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
    #expect(try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? Int == 0o700, "the folder is private")
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

@Test func operatorGrantsAreTaggedAndRevocable() throws {
    let root = URL(fileURLWithPath: "/tmp/vp-op-\(UUID().uuidString.prefix(8))")
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = VMPanePaths(root: root)
    #expect(!OperatorGrant.isGranted(paths: paths))
    try OperatorGrant.grant(paths: paths)
    #expect(OperatorGrant.isGranted(paths: paths))
    #expect(!OperatorGrant.isGranted(paths: paths, uid: getuid() + 1), "another user's")
    try Data("forged".utf8).write(to: root.appendingPathComponent("operator.grant"))
    #expect(!OperatorGrant.isGranted(paths: paths))
    try OperatorGrant.grant(paths: paths)
    try OperatorGrant.revoke(paths: paths)
    #expect(!OperatorGrant.isGranted(paths: paths))
    try OperatorGrant.revoke(paths: paths)  // twice is fine
}

@Test func processAncestryIsReadable() {
    // The test runner's own command line and its parent.
    #expect(!InteractiveSession.arguments(of: getpid()).isEmpty)
    #expect(InteractiveSession.parentPID(of: getpid()) == getppid())
    #expect(!InteractiveSession.underMCP())
}

@Test func theKillSwitchCanOnlyBeTamperedOn() throws {
    let root = URL(fileURLWithPath: "/tmp/vp-ks-\(UUID().uuidString.prefix(8))")
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = VMPanePaths(root: root)
    #expect(!KillSwitch.isEngaged(paths: paths), "no key: nothing to stop")
    _ = PolicyKeyFile(paths: paths).key(create: true)
    #expect(!KillSwitch.isEngaged(paths: paths), "released when the key is made")
    try KillSwitch.engage(paths: paths)
    #expect(KillSwitch.isEngaged(paths: paths))
    try KillSwitch.release(paths: paths)
    #expect(!KillSwitch.isEngaged(paths: paths))
    try FileManager.default.removeItem(at: KillSwitch.url(paths))
    #expect(KillSwitch.isEngaged(paths: paths), "removed: engaged")
    try Data("released\nAAAA\n".utf8).write(to: KillSwitch.url(paths))
    #expect(KillSwitch.isEngaged(paths: paths), "forged: engaged")
}

@Test func theKillSwitchStopsAgentsInTheLibraryToo() throws {
    let root = URL(fileURLWithPath: "/tmp/vp-ksl-\(UUID().uuidString.prefix(8))")
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = VMPanePaths(root: root)
    let agent = LibraryOps(library: VMLibrary(paths: paths), identity: .automated)
    let human = LibraryOps(library: VMLibrary(paths: paths), identity: .operator)
    #expect(try agent.list().isEmpty)
    try KillSwitch.engage(paths: paths)
    #expect(throws: LibraryOps.PolicyDenied.self) { try agent.list() }
    #expect(try human.list().isEmpty, "an operator is not an agent")
}

@Test func letAgentsSignInCountsOnlyWhenTagged() {
    let key = SymmetricKey(size: .bits256)
    // A tag made before the setting existed still holds: the setting off adds nothing to what is signed.
    let before = PolicyIntegrity.signed(config(.control), key: key)
    var unchanged = before
    unchanged.mcp.signIn = false
    #expect(PolicyIntegrity.effective(unchanged, key: key) == .init(level: .control, tampered: false, clipboardAllowWithAgents: false))
    var signIn = config(.control)
    signIn.mcp.signIn = true
    #expect(PolicyIntegrity.effective(PolicyIntegrity.signed(signIn, key: key), key: key).signIn)
    var edited = before
    edited.mcp.signIn = true  // turned on by hand in config.json
    let effective = PolicyIntegrity.effective(edited, key: key)
    #expect(effective.tampered && !effective.signIn && effective.level == .off)
}
