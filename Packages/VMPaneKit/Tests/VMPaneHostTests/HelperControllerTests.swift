import Foundation
import Testing
import VMPaneControl
import VMPaneCore

@testable import VMPaneHost

/// A prepared bundle in a short temp root (socket paths are limited), plus a running controller.
private func withHelper(_ body: (HelperController, VMPanePaths, UUID) async throws -> Void) async throws {
    let root = URL(fileURLWithPath: "/tmp/vp-h-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = VMPanePaths(root: root.appendingPathComponent("s"))
    let config = VMConfigV1(VMConfigFields.new(name: "H", os: .linux, macAddress: MachineIdentity.randomMACAddress()))
    let bundle = try VMBundle.create(at: root.appendingPathComponent("H.vmpane"), config: config)
    try Data("disk".utf8).write(to: bundle.currentDirectory.appendingPathComponent("disk.img"))
    let prepared = try LaunchCoordinator.prepareBundle(bundle, paths: paths, runtimeVersion: "test")
    let controller = HelperController(prepared: prepared, runtimeVersion: "test", backend: nil) {}
    try await controller.start()
    try await body(controller, paths, config.id)
    await controller.shutdown()
}

@Test func helperAnswersHelloInfoAndSnapshots() async throws {
    try await withHelper { _, paths, id in
        let session = try await HelperDiscovery.connect(to: id, paths: paths, clientName: "test", clientVersion: "0", kind: "cli")
        defer { session.client.close() }
        #expect(session.proto == ControlProtocol.version)
        #expect(session.runtimeVersion == "test")

        let info = try await session.client.call("vm.info")
        #expect(info["state"] == "stopped")
        #expect(info["id"] == .string(id.uuidString))
        await #expect(throws: RPCError.self) { try await session.client.call("vm.start", params: ["headless": true]) }

        let created = try await session.client.call("vm.snapshot.create", params: ["name": "before", "kind": "disk"])
        let snapshotID = try #require(created["id"]?.stringValue)
        let list = try await session.client.call("vm.snapshot.list")
        #expect(list == .array([created]))
        let restored = try await session.client.call("vm.snapshot.restore", params: ["id": .string(snapshotID)])
        #expect(restored["generationId"]?.stringValue != nil)
        _ = try await session.client.call("vm.snapshot.delete", params: ["id": .string(snapshotID)])
        #expect(try await session.client.call("vm.snapshot.list") == .array([]))
        await #expect(throws: RPCError.self) { try await session.client.call("vm.snapshot.create", params: ["name": "x", "kind": "live"]) }
    }
}

@Test func helloWithoutASharedVersionIsRefused() async throws {
    try await withHelper { _, paths, id in
        let socket = try #require(HelperDiscovery.socket(for: id, paths: paths))
        let client = try UDSClient.connect(to: socket)
        defer { client.close() }
        do {
            _ = try await client.call(
                "helper.hello",
                params: [
                    "proto": 9, "minProto": 5, "client": ["name": "future", "version": "9", "kind": "cli"],
                ])
            Issue.record("expected protoUnsupported")
        } catch let error as RPCError {
            #expect(error.knownCode == .protoUnsupported)
        }
    }
}

@Test func shutdownRemovesRunFilesAndReleasesTheLock() async throws {
    let root = URL(fileURLWithPath: "/tmp/vp-h-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = VMPanePaths(root: root.appendingPathComponent("s"))
    let config = VMConfigV1(VMConfigFields.new(name: "S", os: .linux, macAddress: MachineIdentity.randomMACAddress()))
    let bundle = try VMBundle.create(at: root.appendingPathComponent("S.vmpane"), config: config)
    let prepared = try LaunchCoordinator.prepareBundle(bundle, paths: paths, runtimeVersion: "t")
    let registry = ChildProcessRegistry(runFiles: prepared.runFiles)
    let child = try registry.spawn(
        URL(fileURLWithPath: "/bin/sleep"),
        .init(arguments: ["300"], inheriting: [prepared.lock.fileDescriptor]))
    let shutdownCalled = Flag()
    let controller = HelperController(prepared: prepared, runtimeVersion: "t", backend: nil) { shutdownCalled.set() }
    try await controller.start()
    #expect(FileManager.default.fileExists(atPath: prepared.runFiles.socketURL.path))
    await controller.shutdown()
    #expect(shutdownCalled.value)
    #expect(!child.isAlive)
    #expect(!FileManager.default.fileExists(atPath: prepared.runFiles.socketURL.path))
    #expect(!FileManager.default.fileExists(atPath: prepared.runFiles.pidURL.path))
    #expect(try bundle.tryLock() != nil)
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set() { lock.withLock { flag = true } }
    var value: Bool { lock.withLock { flag } }
}
