import Foundation
import Testing
import VMPaneCore

@testable import VMPaneHost

@Test func unattendImageCarriesTheXMLAndIsPrivateUntilRemoved() throws {
    let root = URL(fileURLWithPath: "/private/tmp/vp-um-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let config = VMConfigV1(VMConfigFields.new(name: "W", os: .windows, macAddress: "52:54:00:00:00:01"))
    let bundle = try VMBundle.create(at: root.appendingPathComponent("W.vmpane"), config: config)
    let xml = "<?xml version=\"1.0\"?><unattend>marker-\(UUID().uuidString)</unattend>"

    let iso = try UnattendMedia.build(xml, in: bundle)
    #expect(iso == bundle.installDirectory.appendingPathComponent("unattend.iso"))
    #expect(try FileManager.default.attributesOfItem(atPath: iso.path)[.posixPermissions] as? Int == 0o600)
    #expect(try FileManager.default.contentsOfDirectory(atPath: bundle.installDirectory.path) == ["unattend.iso"])  // no staging left

    // Setup finds autounattend.xml at the root of the medium.
    let mount = root.appendingPathComponent("mnt")
    try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
    let attach = try ChildSpawner.spawn(
        URL(fileURLWithPath: "/usr/bin/hdiutil"),
        .init(arguments: ["attach", "-readonly", "-nobrowse", "-quiet", "-mountpoint", mount.path, iso.path]))
    var status: Int32 = 0
    waitpid(attach.pid, &status, 0)
    #expect(status == 0)
    #expect(try String(contentsOf: mount.appendingPathComponent("autounattend.xml"), encoding: .utf8) == xml)
    let detach = try ChildSpawner.spawn(
        URL(fileURLWithPath: "/usr/bin/hdiutil"), .init(arguments: ["detach", "-quiet", "-force", mount.path]))
    waitpid(detach.pid, &status, 0)

    UnattendMedia.remove(from: bundle)
    UnattendMedia.remove(from: bundle)  // idempotent
    #expect(!FileManager.default.fileExists(atPath: iso.path))
}
