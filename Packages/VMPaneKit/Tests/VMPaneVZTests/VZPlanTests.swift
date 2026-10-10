import Foundation
import Testing
import VMPaneCore

@testable import VMPaneVZ

private func linuxConfig() -> VMConfigV1 {
    var config = VMConfigV1(VMConfigFields.new(name: "U", os: .linux, macAddress: "52:54:00:12:34:56"))
    config.platform.machineIdentifier = VZMaterializer.newMachineIdentifier()
    return config
}

/// A real (empty) bundle; the plan tests pretend its files exist.
private func withBundle(_ config: VMConfigV1 = linuxConfig(), _ body: (VMBundle) throws -> Void) throws {
    try withTemp { dir in try body(try VMBundle.create(at: dir.appendingPathComponent("U.vmpane"), config: config)) }
}

private func allExist(_ url: URL) -> Bool { true }

@Test func linuxConfigMapsToAPlan() throws {
    var config = linuxConfig()
    config.cpu.count = 6
    config.memory.mib = 4096
    config.removable = [
        Extensible(RemovableConfig(id: "iso", path: "/isos/u.iso", bus: .usb)),
        Extensible(RemovableConfig(id: "seed", path: "/isos/seed.iso", bus: .virtio)),
    ]
    config.shares = [Extensible(ShareConfig(id: "p", name: "Projects", hostPath: "/Users/me/P", readOnly: true))]
    config.clipboard.mode = .off
    try withBundle { bundle in
        let plan = try VZPlanBuilder.plan(config, bundle: bundle, fileExists: allExist)
        #expect(plan.cpuCount == 6)
        #expect(plan.memoryBytes == 4096 << 20)
        #expect(plan.disks.map(\.kind) == [.virtioBlock, .usbMassStorage, .virtioBlock])
        #expect(plan.disks.map(\.readOnly) == [false, true, true])
        #expect(plan.disks[0].url.path == bundle.url.appendingPathComponent("current/disk.img").path)
        #expect(plan.networks == [.init(macAddress: "52:54:00:12:34:56")])
        #expect(plan.shares == [.init(name: "Projects", url: URL(fileURLWithPath: "/Users/me/P"), readOnly: true)])
        #expect(plan.spiceClipboard == false)
        #expect(plan.serialLog == bundle.logsDirectory.appendingPathComponent("serial.log"))
        guard case .generic(_, let efi, false) = plan.platform else { Issue.record("platform"); return }
        #expect(efi == bundle.auxDirectory.appendingPathComponent("efi_vars.fd"))
    }
}

@Test func planRejectsWhatVZCannotRun() throws {
    try withBundle { bundle in
        var mac = linuxConfig()
        mac.os = .macos
        #expect(throws: VZPlanError.unsupportedGuest(.macos)) { try VZPlanBuilder.plan(mac, bundle: bundle, fileExists: allExist) }

        var noID = linuxConfig()
        noID.platform.machineIdentifier = nil
        #expect(throws: VZPlanError.missingMachineIdentifier) { try VZPlanBuilder.plan(noID, bundle: bundle, fileExists: allExist) }

        var bridged = linuxConfig()
        bridged.network[0].mode = .bridged
        #expect(throws: VZPlanError.bridgedNetworkingUnavailable) { try VZPlanBuilder.plan(bridged, bundle: bundle, fileExists: allExist) }

        var badMAC = linuxConfig()
        badMAC.network[0].macAddress = "zz:00"
        #expect(throws: VZPlanError.invalidMACAddress("zz:00")) { try VZPlanBuilder.plan(badMAC, bundle: bundle, fileExists: allExist) }

        #expect(throws: VZPlanError.missingFile("current/disk.img")) {
            try VZPlanBuilder.plan(linuxConfig(), bundle: bundle, fileExists: { _ in false })
        }
    }
}

@Test func noNetworkModeDropsTheNIC() throws {
    var config = linuxConfig()
    config.network[0].mode = NetworkConfig.Mode.none
    try withBundle { bundle in
        let plan = try VZPlanBuilder.plan(config, bundle: bundle, fileExists: allExist)
        #expect(plan.networks.isEmpty)
    }
}

@Test func prepareAddsAMachineIdentifierOnce() throws {
    var config = linuxConfig()
    config.platform.machineIdentifier = nil
    let prepared = try #require(VZBackend.prepare(config))
    #expect(prepared.platform.machineIdentifier != nil)
    #expect(VZBackend.prepare(prepared) == nil)
}

/// Building the configuration needs no entitlement (only `validate()` does).
@Test func materializerBuildsAConfiguration() throws {
    try withTemp { dir in
        let bundle = try VMBundle.create(at: dir.appendingPathComponent("M.vmpane"), config: linuxConfig())
        try DiskImage.createRaw(at: bundle.currentDirectory.appendingPathComponent("disk.img"), sizeBytes: 1 << 30)
        let plan = try VZPlanBuilder.plan(try ConfigStore.load(bundle), bundle: bundle)
        let configuration = try VZMaterializer.configuration(plan, serialLog: nil)
        #expect(configuration.storageDevices.count == 1)
        #expect(configuration.networkDevices.count == 1)
        #expect(configuration.socketDevices.count == 1)
        #expect(FileManager.default.fileExists(atPath: bundle.auxDirectory.appendingPathComponent("efi_vars.fd").path))
    }
}

private func withTemp(_ body: (URL) throws -> Void) throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vp-vz-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try body(dir)
}
