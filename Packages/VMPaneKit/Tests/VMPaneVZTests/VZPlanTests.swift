import Foundation
import Testing
import VMPaneCore
import Virtualization

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
        var windows = linuxConfig()
        windows.os = .windows
        #expect(throws: VZPlanError.unsupportedGuest(.windows)) { try VZPlanBuilder.plan(windows, bundle: bundle, fileExists: allExist) }

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
        let tags = configuration.directorySharingDevices.compactMap { ($0 as? VZVirtioFileSystemDeviceConfiguration)?.tag }
        #expect(!tags.contains(VZPlan.guestToolsTag))  // an app without guest tools
    }
}

/// Linux guests get the tools on their own read-only tag, next to (not inside) the user's shares.
@Test func linuxGuestToolsAreAReadOnlyShareOfTheirOwn() throws {
    try withTemp { dir in
        let bundle = try VMBundle.create(at: dir.appendingPathComponent("M.vmpane"), config: linuxConfig())
        try DiskImage.createRaw(at: bundle.currentDirectory.appendingPathComponent("disk.img"), sizeBytes: 1 << 30)
        let tools = dir.appendingPathComponent("GuestTools/linux", isDirectory: true)
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
        let plan = try VZPlanBuilder.plan(try ConfigStore.load(bundle), bundle: bundle, guestTools: tools)
        let configuration = try VZMaterializer.configuration(plan, serialLog: nil)
        let devices = configuration.directorySharingDevices.compactMap { $0 as? VZVirtioFileSystemDeviceConfiguration }
            .filter { $0.tag != VZPlan.rosettaTag }
        // The shares device is there without shares too, so folders can be added while the VM runs.
        #expect(devices.map(\.tag) == [VZPlan.sharesTag, VZPlan.guestToolsTag])
        #expect((devices.first?.share as? VZMultipleDirectoryShare)?.directories.isEmpty == true)
        let share = try #require(devices.last?.share as? VZSingleDirectoryShare)
        #expect(share.directory.isReadOnly)
        #expect(share.directory.url == tools)
    }
}

private func withTemp(_ body: (URL) throws -> Void) throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vp-vz-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try body(dir)
}

@Test func macOSGuestInstallsUntilTheInstallFinished() throws {
    var config = VMConfigV1(VMConfigFields.new(name: "M", os: .macos, macAddress: "52:54:00:12:34:57"))
    try withBundle(config) { bundle in
        #expect(throws: VZPlanError.notInstalled) {
            try VZPlanBuilder.plan(config, bundle: bundle, fileExists: { $0.lastPathComponent == "disk.img" })
        }
        config.install = Extensible(InstallConfig(restoreImage: "/ipsw/UniversalMac.ipsw"))
        let installing = try VZPlanBuilder.plan(
            config, bundle: bundle,
            fileExists: { !["HardwareModel", "MachineIdentifier", "AuxiliaryStorage"].contains($0.lastPathComponent) })
        #expect(
            installing.platform
                == .mac(aux: VZMacAux(directory: bundle.auxDirectory), installFrom: URL(fileURLWithPath: "/ipsw/UniversalMac.ipsw")))
        #expect(installing.spiceClipboard == false)
        #expect(installing.rosetta == false)
        // Stopped half-way: the platform files exist but the source is still set, so the install starts again.
        let interrupted = try VZPlanBuilder.plan(config, bundle: bundle, fileExists: allExist)
        #expect(
            interrupted.platform
                == .mac(aux: VZMacAux(directory: bundle.auxDirectory), installFrom: URL(fileURLWithPath: "/ipsw/UniversalMac.ipsw")))
        #expect(throws: VZPlanError.notInstalled) {
            try VZPlanBuilder.plan(config, bundle: bundle, fileExists: { !$0.path.hasPrefix("/ipsw/") })
        }
        config.install = nil  // what `VZBackend.installed` saves after the install
        let installed = try VZPlanBuilder.plan(config, bundle: bundle, fileExists: allExist)
        #expect(installed.platform == .mac(aux: VZMacAux(directory: bundle.auxDirectory), installFrom: nil))
    }
}

@Test func installedRecordsTheMachineIdentifierAndDropsTheSource() throws {
    var config = VMConfigV1(VMConfigFields.new(name: "M", os: .macos, macAddress: "52:54:00:12:34:58"))
    config.install = Extensible(InstallConfig(restoreImage: "/ipsw/x.ipsw"))
    try withBundle(config) { bundle in
        #expect(VZBackend.installed(config, bundle: bundle) == nil)  // not installed yet
        try Data([1, 2, 3]).write(to: VZMacAux(directory: bundle.auxDirectory).machineIdentifier)
        let after = try #require(VZBackend.installed(config, bundle: bundle))
        #expect(after.install == nil)
        #expect(after.platform.machineIdentifier == Data([1, 2, 3]).base64EncodedString())
    }
}

@Test func usKeymapCoversPrintableASCII() {
    for scalar in 0x20...0x7E {
        let character = Character(UnicodeScalar(UInt8(scalar)))
        #expect(VZKeyMap.stroke(for: character) != nil, "no key for \(character)")
    }
    #expect(VZKeyMap.stroke(for: "a") == .init(keyCode: 0, shift: false))
    #expect(VZKeyMap.stroke(for: "A") == .init(keyCode: 0, shift: true))
    #expect(VZKeyMap.stroke(for: "!") == .init(keyCode: 18, shift: true))
    #expect(VZKeyMap.stroke(for: "\n") == .init(keyCode: 36, shift: false))
    #expect(VZKeyMap.stroke(for: "é") == nil)
    #expect(VZKeyMap.keyCode(forHIDUsage: 0x04) == 0)  // A
    #expect(VZKeyMap.keyCode(forHIDUsage: 0x28) == 36)  // Return
    #expect(VZKeyMap.keyCode(forHIDUsage: 0xE1) == 56)  // Left Shift
}

@Test func lockedRestoreErrorsAreRecognised() {
    // As observed on a locked Mac (macOS 15.7): no underlying error, only the failure reason.
    let observed = NSError(
        domain: VZErrorDomain, code: 12,
        userInfo: [NSLocalizedFailureReasonErrorKey: "The virtual machine failed to restore with error “permission denied”."])
    #expect(VZBackend.isLockedRestore(observed))
    let keychain = NSError(domain: NSOSStatusErrorDomain, code: Int(errSecInteractionNotAllowed))
    #expect(VZBackend.isLockedRestore(NSError(domain: VZErrorDomain, code: 12, userInfo: [NSUnderlyingErrorKey: keychain])))
    let other = NSError(domain: VZErrorDomain, code: 12, userInfo: [NSLocalizedFailureReasonErrorKey: "invalid argument"])
    #expect(!VZBackend.isLockedRestore(other))
    #expect(!VZBackend.isLockedRestore(POSIXError(.EIO)))
}

@Test func everyVZKeyHasASharedName() {
    for usage in VZKeyMap.hidUsage.keys {
        #expect(KeyNames.name(forHIDUsage: usage) != nil, "no name for usage \(usage)")
    }
    for character in "abcXYZ019 !@#~\t\n" {
        #expect(KeyNames.stroke(for: character).flatMap { VZKeyMap.keyCode(forHIDUsage: $0.usage) } != nil)
    }
}

/// The display's scaling reaches the plan for Linux; a macOS guest scales itself for Retina, so it stays sharp.
@Test func displayScalingIsLinuxOnly() throws {
    var linux = linuxConfig()
    linux.display.scaling = .standard
    linux.display.autoResize = false
    try withBundle(linux) { bundle in
        let plan = try VZPlanBuilder.plan(linux, bundle: bundle, fileExists: allExist)
        #expect(plan.display.scaling == .standard && !plan.display.autoResize)
    }
    var mac = VMConfigV1(VMConfigFields.new(name: "M", os: .macos, macAddress: "52:54:00:12:34:57"))
    mac.display.scaling = .standard
    #expect(VZPlan.Display(widthPx: 1, heightPx: 1).scaling == .retina)
    try withTemp { dir in
        let bundle = try VMBundle.create(at: dir.appendingPathComponent("M.vmpane"), config: mac)
        if let plan = try? VZPlanBuilder.plan(mac, bundle: bundle, fileExists: allExist) {
            #expect(plan.display.scaling == .retina)
        }
    }
}

/// The window for a guest: half its pixels in points when sharp, the pixels themselves when larger.
@Test @MainActor func displayWindowSizeFollowsScaling() {
    let retina = VZDisplayHost.windowSize(for: NSSize(width: 1280, height: 800), scaling: .retina)
    let standard = VZDisplayHost.windowSize(for: NSSize(width: 1280, height: 800), scaling: .standard)
    #expect(standard.width >= retina.width * 1.9 || standard.width < 1280, "larger unless the screen is too small")
    #expect(abs(standard.width / standard.height - 1.6) < 0.01, "the aspect is kept")
}

/// A `.standard` display boots at its configured size in points, from the settings alone (a saved state resumes only on
/// the same hardware, so never from the screen).
@Test func standardDisplaysBootAtTheirSizeInPoints() {
    #expect(VZPlan.Display(widthPx: 1920, heightPx: 1200).standardBootSize == (960, 600))
    #expect(VZPlan.Display(widthPx: 2560, heightPx: 1600).standardBootSize == (1280, 800))
    #expect(VZPlan.Display(widthPx: 1024, heightPx: 768).standardBootSize == (800, 600), "at least 800 × 600")
    #expect(VZPlan.Display(widthPx: 1922, heightPx: 1202).standardBootSize == (960, 600), "even")
}
