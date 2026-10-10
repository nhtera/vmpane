import Foundation
import Testing

@testable import VMPaneQEMU

/// A directory with a fake `bin/qemu-system-aarch64` (a shell script printing the given outputs).
private func fakeQEMU(version: String = "QEMU emulator version 11.1.2", accelerators: String = "tcg\nhvf") throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("qemu-paths-\(UUID().uuidString)", isDirectory: true)
    let bin = root.appendingPathComponent("bin", isDirectory: true)
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    let script = """
        #!/bin/sh
        case "$1" in
          --version) printf '%s\\n' '\(version)' ;;
          -accel) printf 'Accelerators supported in QEMU binary:\\n\(accelerators)\\n' ;;
          *) exit 1 ;;
        esac
        """
    let qemu = bin.appendingPathComponent("qemu-system-aarch64")
    try script.write(to: qemu, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: qemu.path)
    return root
}

private let runtimeCopy = URL(fileURLWithPath: "/nonexistent/runtime/1.0/qemu", isDirectory: true)
private let debugDir = URL(fileURLWithPath: "/dev-qemu", isDirectory: true)
private let userDir = URL(fileURLWithPath: "/custom-qemu", isDirectory: true)

@Test func runtimeCopyIsTheDefault() throws {
    let inputs = QEMUPaths.Inputs(environment: [:], runtimeCopy: runtimeCopy)
    #expect(try QEMUPaths.select(inputs) == QEMUInstallation(root: runtimeCopy, source: .runtimeCopy))
}

@Test func environmentOverrideOnlyWhenAllowed() throws {
    let env = [QEMUPaths.environmentKey: debugDir.path]
    let allowed = QEMUPaths.Inputs(environment: env, userOverride: userDir, runtimeCopy: runtimeCopy, allowEnvironmentOverride: true)
    #expect(try QEMUPaths.select(allowed) == QEMUInstallation(root: debugDir, source: .environment))
    let ignored = QEMUPaths.Inputs(environment: env, runtimeCopy: runtimeCopy, allowEnvironmentOverride: false)
    #expect(try QEMUPaths.select(ignored).source == .runtimeCopy)
}

/// Runs in both configurations of `scripts/test.sh`: the Release run proves the environment is ignored.
@Test func releaseBuildsIgnoreTheEnvironment() throws {
    let inputs = QEMUPaths.Inputs(environment: [QEMUPaths.environmentKey: debugDir.path], runtimeCopy: runtimeCopy)
    #if DEBUG
        #expect(QEMUPaths.environmentOverrideAllowed)
        #expect(try QEMUPaths.select(inputs).source == .environment)
    #else
        #expect(!QEMUPaths.environmentOverrideAllowed)
        #expect(try QEMUPaths.select(inputs).source == .runtimeCopy)
    #endif
}

@Test func userOverrideBeatsTheRuntimeCopy() throws {
    let inputs = QEMUPaths.Inputs(environment: [:], userOverride: userDir, runtimeCopy: runtimeCopy)
    #expect(try QEMUPaths.select(inputs) == QEMUInstallation(root: userDir, source: .userOverride))
}

@Test func userOverrideIsRefusedForPolicyBoundLaunches() throws {
    let inputs = QEMUPaths.Inputs(environment: [:], userOverride: userDir, policyBoundLaunch: true, runtimeCopy: runtimeCopy)
    #expect(throws: QEMUPathError.overrideNeedsApp(path: userDir.path)) { try QEMUPaths.select(inputs) }
    // Without an override, policy-bound launches use the runtime copy.
    let plain = QEMUPaths.Inputs(environment: [:], policyBoundLaunch: true, runtimeCopy: runtimeCopy)
    #expect(try QEMUPaths.select(plain).source == .runtimeCopy)
}

@Test func validQEMUPassesTheRealProbe() throws {
    let root = try fakeQEMU()
    defer { try? FileManager.default.removeItem(at: root) }
    let inputs = QEMUPaths.Inputs(environment: [:], userOverride: root, runtimeCopy: runtimeCopy)
    #expect(try QEMUPaths.resolve(inputs).root == root)
}

@Test(arguments: [
    ("QEMU emulator version 10.0.12", "tcg\nhvf", "older"),
    ("QEMU emulator version 11.1.2", "tcg", "without HVF"),
    ("garbage", "tcg\nhvf", "--version failed"),
])
func invalidOverrideNamesItsPathWithoutFallback(version: String, accelerators: String, reason: String) throws {
    let root = try fakeQEMU(version: version, accelerators: accelerators)
    defer { try? FileManager.default.removeItem(at: root) }
    let inputs = QEMUPaths.Inputs(environment: [:], userOverride: root, runtimeCopy: runtimeCopy)
    do {
        _ = try QEMUPaths.resolve(inputs)
        Issue.record("resolved an invalid override")
    } catch let error as QEMUPathError {
        guard case .invalid(let path, let message) = error else {
            Issue.record("unexpected \(error)")
            return
        }
        #expect(path == root.path)
        #expect(message.contains(reason))
        #expect(error.description.contains(root.path))
    }
}

@Test func missingBinaryIsInvalid() {
    let inputs = QEMUPaths.Inputs(environment: [:], userOverride: userDir, runtimeCopy: runtimeCopy)
    #expect(throws: QEMUPathError.invalid(path: userDir.path, reason: "no executable bin/qemu-system-aarch64")) {
        try QEMUPaths.resolve(inputs)
    }
}

@Test func parsesProbeOutput() {
    #expect(QEMUPaths.majorVersion("QEMU emulator version 11.1.2 (v11.1.2)\nCopyright") == 11)
    #expect(QEMUPaths.majorVersion("nope") == nil)
    #expect(QEMUPaths.acceleratorList("Accelerators supported in QEMU binary:\ntcg\nhvf\n") == ["tcg", "hvf"])
    #expect(!QEMUPaths.acceleratorList("hvf\ntcg").contains("hvf"))  // the first line is the header
}
