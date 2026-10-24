import Foundation
import Testing
import VMPaneCore

@testable import VMPaneControl
@testable import VMPaneHost

// The app's Install / Update Guest Tools (vm.tools.attach, vm.tools.update).

@Test func aWindowsVMGetsTheToolsDiscFromItsNextBoot() async throws {
    let helper = try await Harness.make(os: .windows)
    defer { Task { await helper.tearDown() } }
    let tools = helper.paths.runtime(version: "t").appendingPathComponent("GuestTools", isDirectory: true)
    try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
    try Data("iso".utf8).write(to: tools.appendingPathComponent("vmpane-guest-tools-windows.iso"))
    let result = try await helper.client.call("vm.tools.attach")
    #expect(result["nextBoot"] == false)  // stopped: its next start has it
    let config = try ConfigStore.load(helper.bundle)
    let disc = try #require(config.removable.first { $0.id == WindowsInstall.toolsID })
    #expect(disc.path == helper.bundle.installDirectory.appendingPathComponent("guest-tools.iso").path)
    #expect(FileManager.default.contents(atPath: disc.path) == Data("iso".utf8))
    // Again: still one disc.
    _ = try await helper.client.call("vm.tools.attach")
    #expect(try ConfigStore.load(helper.bundle).removable.filter { $0.id == WindowsInstall.toolsID }.count == 1)
}

@Test func onlyWindowsVMsTakeTheDiscAndUpdatesNeedRunningTools() async throws {
    let helper = try await Harness.make(os: .linux)
    defer { Task { await helper.tearDown() } }
    await #expect(throws: RPCError.self) { try await helper.client.call("vm.tools.attach") }
    await #expect(throws: RPCError.self) { try await helper.client.call("vm.tools.update") }  // no agent
}

@Test func aToolsDiscAttachedAfterAFailedInstallSurvivesItsCleanup() async throws {
    let helper = try await Harness.make(os: .windows)
    defer { Task { await helper.tearDown() } }
    let config = try ConfigStore.load(helper.bundle)
    let source = helper.root.appendingPathComponent("tools.iso")
    try Data("iso".utf8).write(to: source)
    let iso = try WindowsInstall.placeTools(source, in: helper.bundle)
    let attached = WindowsInstall.withTools(config, iso: iso)  // install already gone from the config
    let cleaned = WindowsInstall.cleanUp(attached, bundle: helper.bundle)  // a later stop repeats the cleanup
    #expect(cleaned.removable.contains { $0.id == WindowsInstall.toolsID })
    #expect(FileManager.default.fileExists(atPath: iso.path))
    // During an install, its own tools disc goes with it.
    var installing = attached
    installing.install = Extensible(InstallConfig(media: WindowsInstall.mediaID))
    #expect(!WindowsInstall.cleanUp(installing, bundle: helper.bundle).removable.contains { $0.id == WindowsInstall.toolsID })
}

@Test func theDiscIsNotAttachedDuringAnInstall() async throws {
    let helper = try await Harness.make(os: .windows) { $0.install = Extensible(InstallConfig(media: "windows")) }
    defer { Task { await helper.tearDown() } }
    await #expect(throws: RPCError.self) { try await helper.client.call("vm.tools.attach") }
}
