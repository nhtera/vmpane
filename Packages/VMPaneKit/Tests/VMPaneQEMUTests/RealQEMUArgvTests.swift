import Foundation
import Testing
import VMPaneCore

@testable import VMPaneQEMU

// Opt-in: VMPANE_QEMU_BUNDLE=<build/qemu-bundle> runs the shipped QEMU (and swtpm) with each argv variant
// and checks that QEMU accepts every option and keeps running (an unknown option or device exits at once).

private let qemuBundle = ProcessInfo.processInfo.environment["VMPANE_QEMU_BUNDLE"]

/// ramfb is not a PCI device, so SPICE cannot record its address for monitor mapping (harmless: ramfb
/// cannot resize anyway). Any other output is a problem.
private let knownWarning = "qemu-system-aarch64: Setting device address of a display device: Not a PCI device."

private func spawn(_ executable: URL, _ arguments: [String], log: URL) throws -> Process {
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    FileManager.default.createFile(atPath: log.path, contents: nil)
    let handle = try FileHandle(forWritingTo: log)
    process.standardOutput = handle
    process.standardError = handle
    try process.run()
    return process
}

/// SIGTERM (never SIGKILL: QEMU exits cleanly on it) and wait.
private func stop(_ process: Process) {
    guard process.isRunning else { return }
    process.terminate()
    process.waitUntilExit()
}

private func variantConfig(_ variant: String, media: URL) throws -> VMConfigV1 {
    var config = try windowsConfig()
    config.memory.mib = 2048
    switch variant {
    case "install":
        config.removable = [
            Extensible(RemovableConfig(id: "win", path: media.path, bus: .usb)),
            Extensible(RemovableConfig(id: "unattend", path: media.path, bus: .usb)),
        ]
        config.install = Extensible(InstallConfig(media: "win"))  // the builder leaves the NIC out
    case "tools":
        config.qemu?.gpu = .virtio
        config.disks.append(Extensible(DiskConfig(id: "data", file: "current/data.img", format: .raw, sizeGiB: 1, bus: .virtio)))
        config.portForwards = [
            Extensible(PortForwardConfig(id: "a", proto: .tcp, hostAddress: "127.0.0.1", hostPort: 47_001, guestPort: 22, origin: .user)),
            Extensible(PortForwardConfig(id: "b", proto: .udp, hostAddress: "127.0.0.1", hostPort: 47_002, guestPort: 53, origin: .user)),
        ]
    case "minimal":
        config.qemu?.tpm = false
        config.audio.output = false
        config.memory.balloon = false
    default:
        break
    }
    return config
}

private func startSwtpm(_ layout: QEMULayout, output: URL) throws -> Process {
    try FileManager.default.createDirectory(at: layout.tpmState, withIntermediateDirectories: true)
    let swtpm = try spawn(
        layout.installation.swtpm,
        [
            "socket", "--tpm2", "--tpmstate", "dir=\(layout.tpmState.path)", "--ctrl", "type=unixio,path=\(layout.tpmSocket.path)",
            "--log", "file=\(layout.swtpmLog.path)", "--terminate",
        ],
        log: output)
    let deadline = Date().addingTimeInterval(10)
    while !FileManager.default.fileExists(atPath: layout.tpmSocket.path), Date() < deadline { usleep(50_000) }
    return swtpm
}

@Test(.enabled(if: qemuBundle != nil), arguments: ["default", "install", "tools", "minimal"])
func realQEMUAcceptsTheArgv(variant: String) async throws {
    let installation = QEMUInstallation(root: URL(fileURLWithPath: try #require(qemuBundle), isDirectory: true), source: .environment)
    // Short and resolved: socket paths must fit sun_path, and /tmp is a symlink.
    let root = URL(fileURLWithPath: "/private/tmp/vp-argv-\(UUID().uuidString.prefix(8))", isDirectory: true)
    let run = root.appendingPathComponent("r", isDirectory: true)
    try FileManager.default.createDirectory(at: run, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    // Media live in the bundle's install/ (the sandbox reads only the bundle and the runtime).
    let bundleURL = root.appendingPathComponent("W.vmpane")
    let media = bundleURL.appendingPathComponent("install/media.iso")
    let config = try variantConfig(variant, media: media)
    let bundle = try VMBundle.create(at: bundleURL, config: config)
    try FileManager.default.createDirectory(at: bundle.installDirectory, withIntermediateDirectories: true)
    try Data(count: 1 << 20).write(to: media)
    for disk in config.disks { try DiskImage.createRaw(at: try bundle.fileURL(relativePath: disk.file), sizeBytes: 1 << 30) }
    let layout = QEMULayout(bundle: bundle, runDirectory: run, installation: installation)
    try QEMUFirmware.ensureVariables(layout)
    try QEMUFirmware.prepareCode(layout)

    let swtpm = config.qemu?.tpm == true ? try startSwtpm(layout, output: root.appendingPathComponent("swtpm.out")) : nil
    defer { swtpm.map(stop) }
    let qemu = try spawn(
        installation.qemuSystem, try QEMUArgvBuilder.arguments(config, layout: layout, incoming: variant == "minimal"), log: layout.qemuLog)
    defer { stop(qemu) }
    let deadline = Date().addingTimeInterval(4)
    while qemu.isRunning, Date() < deadline { usleep(100_000) }

    let output = ((try? String(contentsOf: layout.qemuLog, encoding: .utf8)) ?? "")
        .split(separator: "\n").filter { $0 != knownWarning }.joined(separator: "\n")
    #expect(qemu.isRunning, "QEMU exited: \(output)")
    #expect(FileManager.default.fileExists(atPath: layout.qmpSocket.path))
    #expect(FileManager.default.fileExists(atPath: layout.spiceSocket.path))
    #expect(output.isEmpty, "QEMU printed: \(output)")

    // The QMP client against the real QEMU: status, then a clean quit.
    let qmp = try await QMPClient.connect(to: layout.qmpSocket)
    let status = try await qmp.execute("query-status")["status"]
    #expect(status == (variant == "minimal" ? "inmigrate" : "running"))
    if variant == "install" {
        // After Setup's first reboot the install medium is ejected: a CD-ROM under its usb-storage device.
        guard case .array(let blocks) = try await qmp.execute("query-block") else { Issue.record("query-block"); return }
        let entry = try #require(blocks.first { $0["qdev"]?.stringValue?.contains("media0-dev") == true })
        #expect(entry["removable"] == true && entry["inserted"]?["ro"] == true)
        let medium = try #require(entry["qdev"]?.stringValue)
        try await qmp.execute("eject", ["id": .string(medium), "force": true])
        guard case .array(let after) = try await qmp.execute("query-block") else { return }
        #expect(after.first { $0["qdev"]?.stringValue == medium }?["inserted"] == nil)
    }
    if variant == "default" {
        // Every key name in the shared table is a QKeyCode this QEMU knows (an unknown one is an error).
        for name in Set(KeyNames.names.values) {
            let release: JSONValue = ["type": "key", "data": ["down": false, "key": ["type": "qcode", "data": .string(name)]]]
            try await qmp.execute("input-send-event", ["events": [release]])
        }
    }
    try await qmp.execute("quit")
    qemu.waitUntilExit()
    #expect(qemu.terminationStatus == 0)
}
