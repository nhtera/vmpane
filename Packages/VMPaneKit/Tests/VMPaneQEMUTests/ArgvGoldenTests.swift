import Foundation
import Testing
import VMPaneCore

@testable import VMPaneQEMU

// Golden argv per config variant: `Golden/<name>.args`, one argument per line, with the bundle path shown as
// <bundle>. Regenerate with VMPANE_UPDATE_GOLDEN=1 and review the diff.

private let runDirectory = URL(fileURLWithPath: "/run/abcd1234", isDirectory: true)
private let installation = QEMUInstallation(
    root: URL(fileURLWithPath: "/runtime/1.0-q12345678/qemu", isDirectory: true), source: .runtimeCopy)

func windowsConfig() throws -> VMConfigV1 {
    var config = VMConfigV1(
        VMConfigFields.new(
            id: try #require(UUID(uuidString: "6A1F0C2E-0000-4000-8000-000000000001")), name: "Windows 11", os: .windows,
            macAddress: "52:54:00:AB:CD:EF"))
    config.qemu?.smbiosUUID = try #require(UUID(uuidString: "11111111-2222-4333-8444-555555555555"))
    return config
}

private func withBundle(named name: String = "Win.vmpane", _ config: VMConfigV1, _ body: (QEMULayout) throws -> Void) throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vp-qemu-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let bundle = try VMBundle.create(at: dir.appendingPathComponent(name), config: config)
    try body(QEMULayout(bundle: bundle, runDirectory: runDirectory, installation: installation))
}

private func allExist(_ url: URL) -> Bool { true }

private func expectGolden(_ name: String, _ args: [String], layout: QEMULayout, sourceFile: String = #filePath) throws {
    let bundlePath = layout.bundle.url.path
    let shown = args.map {
        $0.replacingOccurrences(of: QEMUArgvBuilder.escape(bundlePath), with: "<bundle>")
            .replacingOccurrences(of: bundlePath, with: "<bundle>")
    }
    let text = shown.joined(separator: "\n") + "\n"
    let golden = URL(fileURLWithPath: sourceFile).deletingLastPathComponent().appendingPathComponent("Golden/\(name).args")
    if ProcessInfo.processInfo.environment["VMPANE_UPDATE_GOLDEN"] == "1" {
        try FileManager.default.createDirectory(at: golden.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: golden, atomically: true, encoding: .utf8)
        return
    }
    let expected = try String(contentsOf: golden, encoding: .utf8)
    #expect(text == expected, "argv differs from Golden/\(name).args (VMPANE_UPDATE_GOLDEN=1 regenerates)")
}

@Test func defaultWindowsVM() throws {
    let config = try windowsConfig()
    try withBundle(config) { layout in
        try expectGolden("windows-default", try QEMUArgvBuilder.arguments(config, layout: layout, fileExists: allExist), layout: layout)
    }
}

/// Phase 06 install: Windows ISO boots first from USB, unattend + tools ISOs, no NIC.
@Test func installFromISOWithoutNetwork() throws {
    var config = try windowsConfig()
    config.removable = [
        Extensible(RemovableConfig(id: "win-iso", path: "/Users/me/Downloads/Win11_ARM64.iso", bus: .usb)),
        Extensible(RemovableConfig(id: "unattend", path: "/tmp/unattend.iso", bus: .usb)),
    ]
    config.install = Extensible(InstallConfig(media: "win-iso"))
    config.network = []
    try withBundle(config) { layout in
        try expectGolden("windows-install", try QEMUArgvBuilder.arguments(config, layout: layout, fileExists: allExist), layout: layout)
    }
}

/// After guest tools: virtio GPU, a data disk on virtio, port forwards.
@Test func afterGuestToolsWithForwardsAndDataDisk() throws {
    var config = try windowsConfig()
    config.qemu?.gpu = .virtio
    config.disks.append(Extensible(DiskConfig(id: "data", file: "current/data.img", format: .raw, sizeGiB: 32, bus: .virtio)))
    config.portForwards = [
        Extensible(PortForwardConfig(id: "rdp", proto: .tcp, hostAddress: "127.0.0.1", hostPort: 13389, guestPort: 3389, origin: .user)),
        Extensible(PortForwardConfig(id: "dns", proto: .udp, hostAddress: "0.0.0.0", hostPort: 5353, guestPort: 53, origin: .agent)),
    ]
    try withBundle(config) { layout in
        try expectGolden("windows-tools", try QEMUArgvBuilder.arguments(config, layout: layout, fileExists: allExist), layout: layout)
    }
}

/// No TPM, no sound, no balloon, restoring saved RAM state.
@Test func minimalRestoringState() throws {
    var config = try windowsConfig()
    config.qemu?.tpm = false
    config.audio.output = false
    config.memory.balloon = false
    config.cpu.count = 2
    config.memory.mib = 4096
    try withBundle(config) { layout in
        try expectGolden(
            "windows-minimal-incoming", try QEMUArgvBuilder.arguments(config, layout: layout, incoming: true, fileExists: allExist),
            layout: layout)
    }
}

@Test func commasInNamesAndPathsAreEscaped() throws {
    var config = try windowsConfig()
    config.name = "Win, file=/etc/passwd"
    config.removable = [Extensible(RemovableConfig(id: "iso", path: "/isos/a,readonly=off.iso", bus: .usb))]
    try withBundle(named: "Win, Test.vmpane", config) { layout in
        let args = try QEMUArgvBuilder.arguments(config, layout: layout, fileExists: allExist)
        #expect(!args.contains { $0.contains("passwd") })  // the VM name never reaches QEMU
        #expect(args.contains { $0.hasSuffix("file.filename=/isos/a,,readonly=off.iso") })
        try expectGolden("windows-commas", args, layout: layout)
    }
}

@Test func rejectsWhatQEMUMustNotRun() throws {
    let base = try windowsConfig()
    try withBundle(base) { layout in
        func rejects(_ error: QEMUConfigError, _ change: (inout VMConfigV1) -> Void) {
            var config = base
            change(&config)
            #expect(throws: error) { try QEMUArgvBuilder.arguments(config, layout: layout, fileExists: allExist) }
        }
        rejects(.unsupportedGuest(.linux)) { $0.os = .linux }
        rejects(.missingQEMUSettings) { $0.qemu = nil }
        rejects(.secureBootRequired) { $0.qemu?.secureBoot = false }
        rejects(.bridgedNetworkingUnavailable) { $0.network[0].mode = .bridged }
        rejects(.invalidMACAddress("52:54:00:ab:cd")) { $0.network[0].macAddress = "52:54:00:ab:cd" }
        rejects(.invalidMACAddress("52:54:00:ab:cd:e,")) { $0.network[0].macAddress = "52:54:00:ab:cd:e," }
        for address in ["localhost", "1.2.3", "::1", "1.2.3.4,hostfwd=tcp::1-:2", "1.2.3.256", " 1.2.3.4"] {
            rejects(.invalidPortForward(id: "x")) {
                $0.portForwards = [
                    Extensible(PortForwardConfig(id: "x", proto: .tcp, hostAddress: address, hostPort: 80, guestPort: 80, origin: .agent))
                ]
            }
        }
        for (host, guest) in [(0, 80), (80, 65536), (-1, 80)] {
            rejects(.invalidPortForward(id: "p")) {
                $0.portForwards = [
                    Extensible(
                        PortForwardConfig(id: "p", proto: .tcp, hostAddress: "127.0.0.1", hostPort: host, guestPort: guest, origin: .user))
                ]
            }
        }
        var missing = base
        missing.removable = [Extensible(RemovableConfig(id: "iso", path: "/nonexistent.iso", bus: .usb))]
        #expect(throws: QEMUConfigError.missingFile("current/disk.img")) { try QEMUArgvBuilder.arguments(missing, layout: layout) }
        #expect(throws: QEMUConfigError.missingFile("/nonexistent.iso")) {
            try QEMUArgvBuilder.arguments(missing, layout: layout, fileExists: { $0.lastPathComponent == "disk.img" })
        }
        var escaping = base
        escaping.disks[0].file = "../outside.img"
        #expect(throws: BundleError.unsafePath("../outside.img")) {
            try QEMUArgvBuilder.arguments(escaping, layout: layout, fileExists: allExist)
        }
    }
}

@Test func socketPathsMustFitSunPath() throws {
    let config = try windowsConfig()
    try withBundle(config) { layout in
        var long = layout
        long.runDirectory = URL(fileURLWithPath: "/" + String(repeating: "r", count: 92), isDirectory: true)
        #expect(throws: QEMUConfigError.socketPathTooLong(long.spiceSocket.path)) {
            try QEMUArgvBuilder.arguments(config, layout: long, fileExists: allExist)
        }
    }
}

@Test func firmwareIsPaddedToTheFlashSizeAndVariablesAreKept() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vp-fw-\(UUID().uuidString)", isDirectory: true)
    let share = dir.appendingPathComponent("qemu/share", isDirectory: true)
    let run = dir.appendingPathComponent("run", isDirectory: true)
    try FileManager.default.createDirectory(at: share, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: run, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try Data(repeating: 0xC0, count: 2 << 20).write(to: share.appendingPathComponent("edk2-aarch64-code.fd"))
    try Data(repeating: 0x5A, count: 768 << 10).write(to: share.appendingPathComponent("edk2-aarch64-vars-sb.fd"))
    let bundle = try VMBundle.create(at: dir.appendingPathComponent("W.vmpane"), config: try windowsConfig())
    let layout = QEMULayout(
        bundle: bundle, runDirectory: run, installation: QEMUInstallation(root: dir.appendingPathComponent("qemu"), source: .runtimeCopy))

    #expect(try QEMUFirmware.ensureVariables(layout))
    let vars = try Data(contentsOf: layout.efiVariables)
    #expect(vars.count == 64 << 20)
    #expect(vars.prefix(768 << 10).allSatisfy { $0 == 0x5A } && vars.suffix(1024).allSatisfy { $0 == 0 })
    #expect(try FileManager.default.attributesOfItem(atPath: layout.efiVariables.path)[.posixPermissions] as? Int == 0o600)

    // The VM's variables (boot entries, keys) are never replaced by the template.
    try Data(repeating: 0x77, count: 16).write(to: layout.efiVariables)
    #expect(try QEMUFirmware.ensureVariables(layout) == false)
    #expect(try Data(contentsOf: layout.efiVariables) == Data(repeating: 0x77, count: 16))

    try QEMUFirmware.prepareCode(layout)
    try QEMUFirmware.prepareCode(layout)  // replaced on every start
    let code = try Data(contentsOf: layout.firmwareCode)
    #expect(code.count == 64 << 20 && code.prefix(2 << 20).allSatisfy { $0 == 0xC0 })
    #expect(try FileManager.default.contentsOfDirectory(atPath: run.path) == ["efi_code.fd"])
}
