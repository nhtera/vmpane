import CryptoKit
import Foundation
import Testing

@testable import VMPaneCore

// What the helper needs to update older guest tools: which version is older, and the files it may send.

@Test func releaseVersionsOrderAsSemanticVersioning() throws {
    let ordered = [
        "1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-beta.2", "1.0.0-beta.10", "1.0.0-beta.11", "1.0.0-rc.1", "1.0.0", "1.0.1", "1.1.0",
        "2.0.0",
    ]
    let versions = try ordered.map { try #require(ReleaseVersion($0)) }
    for (older, newer) in zip(versions, versions.dropFirst()) {
        #expect(older < newer, "\(older) < \(newer)")
        #expect(!(newer < older))
    }
    #expect(ReleaseVersion("1.0.0-beta.11+abc") == ReleaseVersion("1.0.0-beta.11"))
    #expect(ReleaseVersion("1.0.0-beta.11")?.description == "1.0.0-beta.11")
    for bad in ["", "test", "1.0", "1.0.0.1", "1.0.0-", "1.0.0-beta..1", "1.-1.0", "v1.0.0"] {
        #expect(ReleaseVersion(bad) == nil, "\(bad)")
    }
}

/// `runtime/<v>/GuestTools/<os>/` with `files` and a SHA256SUMS over them (`tamper` changed after).
private func runtime(_ os: String, _ files: [String: String], tamper: String? = nil) throws -> URL {
    let runtime = URL(fileURLWithPath: "/tmp/vp-gt-\(UUID().uuidString.prefix(8))", isDirectory: true)
    let folder = runtime.appendingPathComponent("GuestTools/\(os)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    var sums = ""
    for (name, content) in files.sorted(by: { $0.key < $1.key }) {
        try Data(content.utf8).write(to: folder.appendingPathComponent(name))
        sums += SHA256.hash(data: Data(content.utf8)).map { String(format: "%02x", $0) }.joined() + "  \(name)\n"
    }
    try sums.write(to: folder.appendingPathComponent("SHA256SUMS"), atomically: true, encoding: .utf8)
    if let tamper { try Data("changed".utf8).write(to: folder.appendingPathComponent(tamper)) }
    return runtime
}

@Test func onlyToolsMatchingTheirChecksumsAreSent() throws {
    let linux = try runtime("linux", ["install.sh": "#!/bin/sh", "vmpane-agent": "elf"])
    defer { try? FileManager.default.removeItem(at: linux) }
    let package = try GuestToolsPackage.verified(.linux, runtime: linux)
    #expect(package.files == ["install.sh", "vmpane-agent"])
    #expect(package.sha256["vmpane-agent"] == SHA256.hash(data: Data("elf".utf8)).map { String(format: "%02x", $0) }.joined())
    #expect(package.folder.lastPathComponent == "linux")

    let tampered = try runtime("linux", ["install.sh": "#!/bin/sh", "vmpane-agent": "elf"], tamper: "vmpane-agent")
    defer { try? FileManager.default.removeItem(at: tampered) }
    #expect(throws: GuestToolsPackage.Problem.self) { try GuestToolsPackage.verified(.linux, runtime: tampered) }

    let noInstaller = try runtime("windows", ["README.txt": "hi"])
    defer { try? FileManager.default.removeItem(at: noInstaller) }
    #expect(throws: GuestToolsPackage.Problem.self) { try GuestToolsPackage.verified(.windows, runtime: noInstaller) }

    let windows = try runtime("windows", ["vmpane-agent.msi": "msi"])
    defer { try? FileManager.default.removeItem(at: windows) }
    #expect(try GuestToolsPackage.verified(.windows, runtime: windows).files == ["vmpane-agent.msi"])
    // None for macOS (updated by hand), nor where the app has no tools.
    #expect(throws: GuestToolsPackage.Problem.self) { try GuestToolsPackage.verified(.macos, runtime: windows) }
    #expect(throws: GuestToolsPackage.Problem.self) { try GuestToolsPackage.verified(.linux, runtime: windows) }
}

@Test func aChecksumListNamingAFileElsewhereIsRefused() throws {
    let linux = try runtime("linux", ["install.sh": "#!/bin/sh"])
    defer { try? FileManager.default.removeItem(at: linux) }
    let sums = linux.appendingPathComponent("GuestTools/linux/SHA256SUMS")
    try (String(contentsOf: sums, encoding: .utf8) + "\(String(repeating: "0", count: 64))  ../../secret\n")
        .write(to: sums, atomically: true, encoding: .utf8)
    #expect(throws: GuestToolsPackage.Problem.self) { try GuestToolsPackage.verified(.linux, runtime: linux) }
}

@Test func guestToolsUpdateByDefaultAndTheSwitchAppliesAtOnce() throws {
    let config = AgentConfig(transport: .auto)
    #expect(config.updatesTools)
    let decoded = try JSONDecoder().decode(AgentConfig.self, from: Data(#"{"transport":"auto"}"#.utf8))
    #expect(decoded.updatesTools && decoded.autoUpdate == nil)
    var off = config
    off.updatesTools = false
    #expect(off.autoUpdate == false)
    off.updatesTools = true
    #expect(off.autoUpdate == nil)  // back to absent, as it was
    #expect(SettingsPatch.kind(of: "agent.autoUpdate") == .host)
    #expect(SettingsPatch.kind(of: "agent.transport") == .nextBoot)
}
