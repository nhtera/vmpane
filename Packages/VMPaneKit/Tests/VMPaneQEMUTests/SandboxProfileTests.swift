import Foundation
import Testing
import VMPaneCore

@testable import VMPaneQEMU

@Test func profilesShipWithTheModule() throws {
    for program in QEMUSandbox.Program.allCases {
        let text = try String(contentsOf: try QEMUSandbox.profile(program), encoding: .utf8)
        #expect(text.contains("(deny default)"), "\(program) profile is not deny-by-default")
        for parameter in ["BUNDLE", "RUNDIR", "RUNTIME"] { #expect(text.contains("(param \"\(parameter)\")")) }
    }
    // swtpm gets no network and no hypervisor.
    let swtpm = try String(contentsOf: try QEMUSandbox.profile(.swtpm), encoding: .utf8)
    #expect(!swtpm.contains("AppleHVUserClient") && !swtpm.contains("network-outbound"))
}

@Test func sandboxArgumentsUseRealPaths() throws {
    // /tmp is a symlink: rules match resolved paths, so parameters must be resolved.
    let root = URL(fileURLWithPath: "/tmp/vp-sbx-\(UUID().uuidString.prefix(8))", isDirectory: true)
    let run = root.appendingPathComponent("run", isDirectory: true)
    let runtime = root.appendingPathComponent("runtime/qemu", isDirectory: true)
    try FileManager.default.createDirectory(at: run, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let bundle = try VMBundle.create(at: root.appendingPathComponent("W.vmpane"), config: try windowsConfig())
    let layout = QEMULayout(bundle: bundle, runDirectory: run, installation: QEMUInstallation(root: runtime, source: .runtimeCopy))

    let args = try QEMUSandbox.arguments(.swtpm, executable: layout.installation.swtpm, arguments: ["socket", "--tpm2"], layout: layout)
    let real = "/private" + root.path
    #expect(
        args == [
            "-f", try QEMUSandbox.profile(.swtpm).path, "-D", "BUNDLE=\(real)/W.vmpane", "-D", "RUNDIR=\(real)/run",
            "-D", "RUNTIME=\(real)/runtime/qemu", runtime.appendingPathComponent("bin/swtpm").path, "socket", "--tpm2",
        ])
    var missing = layout
    missing.runDirectory = root.appendingPathComponent("nonexistent")
    #expect(throws: POSIXError.self) { try QEMUSandbox.arguments(.qemu, executable: runtime, arguments: [], layout: missing) }
}
