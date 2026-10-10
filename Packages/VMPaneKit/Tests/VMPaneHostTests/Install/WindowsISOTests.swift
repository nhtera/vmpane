import Foundation
import Testing
import VMPaneCore

@testable import VMPaneHost

/// A WIM file as Windows media carry it: the 208-byte header (magic MSWIM) pointing at a UTF-16LE XML image list.
private struct FakeImage {
    var name: String
    var arch: Int
    var build: Int
}

private func makeWIM(_ images: [FakeImage], compressed: Bool = false, xmlSize: Int? = nil) -> Data {
    var xml = "<WIM><TOTALBYTES>1</TOTALBYTES>"
    for (index, image) in images.enumerated() {
        xml += "<IMAGE INDEX=\"\(index + 1)\"><NAME>\(image.name)</NAME><WINDOWS><ARCH>\(image.arch)</ARCH>"
        xml += "<VERSION><MAJOR>10</MAJOR><MINOR>0</MINOR><BUILD>\(image.build)</BUILD></VERSION></WINDOWS></IMAGE>"
    }
    xml += "</WIM>"
    let body = Data([0xFF, 0xFE]) + (xml.data(using: .utf16LittleEndian) ?? Data())
    var header = Data(count: 208)
    header.replaceSubrange(0..<8, with: Data("MSWIM\0\0\0".utf8))
    let size = UInt64(xmlSize ?? body.count)
    for byte in 0..<7 { header[0x48 + byte] = UInt8((size >> (8 * UInt64(byte))) & 0xFF) }
    header[0x4F] = compressed ? 0x04 : 0x02
    for byte in 0..<8 { header[0x50 + byte] = UInt8((UInt64(208) >> (8 * UInt64(byte))) & 0xFF) }
    return header + body
}

private func withTemp(_ body: (URL) throws -> Void) throws {
    let dir = URL(fileURLWithPath: "/private/tmp/vp-iso-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try body(dir)
}

/// An unpacked install medium: optional arm64 loader and install image.
private func makeMedia(at root: URL, loader: Bool = true, wim: Data?) throws {
    if loader {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("efi/boot"), withIntermediateDirectories: true)
        try Data("efi".utf8).write(to: root.appendingPathComponent("efi/boot/bootaa64.efi"))
    }
    if let wim {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("sources"), withIntermediateDirectories: true)
        try wim.write(to: root.appendingPathComponent("sources/install.wim"))
    }
}

@Test func wimImageListIsRead() throws {
    try withTemp { dir in
        let file = dir.appendingPathComponent("install.wim")
        try makeWIM([
            FakeImage(name: "Windows 11 Home", arch: 12, build: 26100), FakeImage(name: "Windows 11 Pro", arch: 12, build: 26100),
            FakeImage(name: "Windows 10 Pro", arch: 9, build: 19045),
        ]).write(to: file)
        let images = try WIMHeaderReader.images(of: file)
        #expect(images.map(\.name) == ["Windows 11 Home", "Windows 11 Pro", "Windows 10 Pro"])
        #expect(images.map(\.isARM64) == [true, true, false])
        #expect(images.map(\.isWindows11) == [true, true, false])
        #expect(images[1].index == 2)

        try makeWIM([FakeImage(name: "X", arch: 12, build: 26100)], compressed: true).write(to: file)
        #expect(throws: WIMHeaderError.unreadableImageList) { try WIMHeaderReader.images(of: file) }
        try makeWIM([FakeImage(name: "X", arch: 12, build: 26100)], xmlSize: 64 << 20).write(to: file)
        #expect(throws: WIMHeaderError.unreadableImageList) { try WIMHeaderReader.images(of: file) }
        try Data("not a wim at all, just text that is long enough to be read as a header ......".utf8).write(to: file)
        #expect(throws: WIMHeaderError.notAWIM) { try WIMHeaderReader.images(of: file) }
    }
}

@Test func inspectorSortsMediaByWhatTheyCanInstall() throws {
    try withTemp { dir in
        func verdict(_ name: String, loader: Bool = true, wim: Data?) throws -> WindowsISOInspector.Verdict {
            let root = dir.appendingPathComponent(name)
            try makeMedia(at: root, loader: loader, wim: wim)
            return WindowsISOInspector.inspect(mounted: root)
        }
        guard
            case .windows11(let editions) = try verdict(
                "ok",
                wim: makeWIM([
                    FakeImage(name: "Windows 11 Pro", arch: 12, build: 26300), FakeImage(name: "Windows 11 Home", arch: 12, build: 26300),
                ]))
        else { Issue.record("expected Windows 11"); return }
        #expect(editions.map(\.name) == ["Windows 11 Pro", "Windows 11 Home"])
        #expect(try verdict("x64", wim: makeWIM([FakeImage(name: "Windows 11 Pro", arch: 9, build: 26100)])) == .notArm64)
        #expect(
            try verdict("noloader", loader: false, wim: makeWIM([FakeImage(name: "Windows 11 Pro", arch: 12, build: 26100)])) == .notArm64)
        #expect(
            try verdict("win10", wim: makeWIM([FakeImage(name: "Windows 10 Pro", arch: 12, build: 19045)])) == .notWindows11(build: 19045))
        #expect(try verdict("linux", wim: nil) == .notWindows)
        #expect(try verdict("empty", loader: false, wim: nil) == .notArm64)
    }
}

/// End to end on a real ISO image (UDF + Joliet like Microsoft's), mounted read-only by hdiutil.
@Test func inspectorReadsAnISOImage() throws {
    try withTemp { dir in
        let root = dir.appendingPathComponent("media")
        try makeMedia(at: root, wim: makeWIM([FakeImage(name: "Windows 11 Pro", arch: 12, build: 26300)]))
        let iso = dir.appendingPathComponent("win.iso")
        let tool = try ChildSpawner.spawn(
            URL(fileURLWithPath: "/usr/bin/hdiutil"),
            .init(arguments: ["makehybrid", "-quiet", "-udf", "-iso", "-joliet", "-o", iso.path, root.path]))
        var status: Int32 = 0
        waitpid(tool.pid, &status, 0)
        #expect(status == 0)
        guard case .windows11(let editions) = WindowsISOInspector.inspect(iso) else { Issue.record("not recognised"); return }
        #expect(editions.map(\.name) == ["Windows 11 Pro"])
        #expect(WindowsISOInspector.inspect(dir.appendingPathComponent("missing.iso")) == .unreadable)
    }
}

private let accepted = Date(timeIntervalSince1970: 1_791_590_400)

private func input(edition: String = "Windows 11 Pro") -> UnattendInput {
    UnattendInput(
        locale: "en-US", timeZone: "UTC", computerName: "WIN11", userName: "vmpane", password: "secret-\(UUID().uuidString)",
        editionName: edition, eulaAcceptedAt: accepted)
}

@Test func installIsPreparedInsideTheBundleWithoutThePasswordInTheConfig() throws {
    try withTemp { dir in
        var config = VMConfigV1(VMConfigFields.new(name: "W", os: .windows, macAddress: "52:54:00:00:00:02"))
        config.qemu?.gpu = .virtio
        let bundle = try VMBundle.create(at: dir.appendingPathComponent("W.vmpane"), config: config)
        let lock = try #require(try bundle.tryLock(retryingFor: 5))
        let iso = dir.appendingPathComponent("Win11_ARM64.iso"), tools = dir.appendingPathComponent("tools.iso")
        try Data(count: 1 << 20).write(to: iso)
        try Data(count: 1 << 16).write(to: tools)
        let windows11: (URL) -> WindowsISOInspector.Verdict = { _ in
            .windows11(editions: [WindowsImage(index: 1, name: "Windows 11 Pro", architecture: 12, build: 26300)])
        }
        let account = input()

        let prepared = try WindowsInstall.prepare(
            config, iso: iso, input: account, tools: tools, holding: lock, freeBytes: { _ in 100 << 30 }, inspect: windows11)
        #expect(prepared.install?.media == "windows")
        #expect(prepared.removable.map(\.id) == ["windows", "unattend", "tools"])
        #expect(prepared.removable.allSatisfy { $0.path.hasPrefix(bundle.installDirectory.path) && $0.bus == .usb })
        #expect(prepared.qemu?.gpu == .ramfb && prepared.windows?.eulaAcceptedAt == accepted)
        #expect(!(String(bytes: try CanonicalJSON.encode(prepared), encoding: .utf8) ?? "").contains(account.password))
        for entry in try FileManager.default.contentsOfDirectory(atPath: bundle.installDirectory.path) {
            #expect(
                try FileManager.default.attributesOfItem(atPath: bundle.installDirectory.appendingPathComponent(entry).path)[
                    .posixPermissions] as? Int == 0o600)
        }

        // Every ending runs the same cleanup: the password and the ISO copies are gone, the config is back.
        let cleaned = WindowsInstall.cleanUp(prepared, bundle: bundle)
        #expect(cleaned.install == nil && cleaned.removable.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: bundle.installDirectory.path).isEmpty)
        _ = WindowsInstall.cleanUp(cleaned, bundle: bundle)  // repeatable
    }
}

@Test func installIsRefusedForWrongMediaEditionsOrSpace() throws {
    try withTemp { dir in
        let config = VMConfigV1(VMConfigFields.new(name: "W", os: .windows, macAddress: "52:54:00:00:00:03"))
        let bundle = try VMBundle.create(at: dir.appendingPathComponent("W.vmpane"), config: config)
        let lock = try #require(try bundle.tryLock(retryingFor: 5))
        let iso = dir.appendingPathComponent("x.iso")
        try Data(count: 1024).write(to: iso)
        func prepare(_ verdict: WindowsISOInspector.Verdict, edition: String = "Windows 11 Pro", free: UInt64 = 100 << 30) throws {
            _ = try WindowsInstall.prepare(
                config, iso: iso, input: input(edition: edition), tools: nil, holding: lock, freeBytes: { _ in free },
                inspect: { _ in verdict })
        }
        let pro = WindowsImage(index: 1, name: "Windows 11 Pro", architecture: 12, build: 26300)
        #expect(throws: WindowsInstallError.notArm64) { try prepare(.notArm64) }
        #expect(throws: WindowsInstallError.notWindows11(build: 19045)) { try prepare(.notWindows11(build: 19045)) }
        #expect(throws: WindowsInstallError.editionMissing("Windows 11 Home", available: ["Windows 11 Pro"])) {
            try prepare(.windows11(editions: [pro]), edition: "Windows 11 Home")
        }
        #expect(throws: InsufficientSpace.self) { try prepare(.windows11(editions: [pro]), free: 5 << 30) }
        #expect(!FileManager.default.fileExists(atPath: bundle.installDirectory.appendingPathComponent("unattend.iso").path))

        var linux = config
        linux.os = .linux
        #expect(throws: WindowsInstallError.notWindowsVM) {
            _ = try WindowsInstall.prepare(
                linux, iso: iso, input: input(), tools: nil, holding: lock, inspect: { _ in .windows11(editions: [pro]) })
        }
    }
}
