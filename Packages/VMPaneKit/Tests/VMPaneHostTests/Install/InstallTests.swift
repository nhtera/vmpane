import CryptoKit
import Foundation
import Testing
import VMPaneCore

@testable import VMPaneHost

@Test func catalogsArePinnedAndSecure() throws {
    for catalog in [try ImageCatalog.macOS(), try ImageCatalog.linux()] {
        #expect(!catalog.images.isEmpty)
        #expect(Set(catalog.images.map(\.id)).count == catalog.images.count)
        for image in catalog.images {
            #expect(image.url.scheme == "https", "\(image.id)")
            #expect(image.sha256.count == 64 && image.sha256.allSatisfy(\.isHexDigit), "\(image.id)")
            #expect(image.sizeBytes > 0)
        }
    }
    #expect(try ImageCatalog.macOS().images.first?.build == "24G90")
}

@Test func catalogTitlesNameTheVersionOnceAndTheCacheKnowsWhatItHas() throws {
    let mac = try #require(try ImageCatalog.macOS().images.first)
    #expect(mac.title.components(separatedBy: mac.version).count == 2)  // "macOS Sequoia 15.6.1", not "… 15.6.1 15.6.1"
    var ubuntu = mac
    (ubuntu.name, ubuntu.version) = ("Ubuntu Server", "24.04")
    #expect(ubuntu.title == "Ubuntu Server 24.04")

    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vp-cache-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let cache = ImageCache(directory: dir)
    #expect(!cache.has(mac))
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try Data().write(to: cache.file(for: mac))
    #expect(cache.has(mac))
}

/// Serves `StubServer.body` for https://stub.test/file, honouring Range; optionally drops the connection
/// after `cutAfter` bytes, or ignores Range.
final class StubServer: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var body = Data()
    nonisolated(unsafe) static var cutAfter: Int?
    nonisolated(unsafe) static var ignoreRange = false
    nonisolated(unsafe) static var rangesSeen: [String] = []

    override static func canInit(with request: URLRequest) -> Bool { request.url?.host == "stub.test" }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let client else { return }
        var start = 0
        var status = 200
        if let range = request.value(forHTTPHeaderField: "Range"), !Self.ignoreRange {
            Self.rangesSeen.append(range)
            start = Int(range.dropFirst("bytes=".count).dropLast()) ?? 0
            status = 206
        }
        let slice = Self.body[start...]
        guard
            let response = HTTPURLResponse(
                url: url, statusCode: status, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Length": "\(slice.count)"])
        else { return }
        client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if let cut = Self.cutAfter {
            // The connection ends early: fewer bytes than Content-Length announced.
            Self.cutAfter = nil
            client.urlProtocol(self, didLoad: Data(slice.prefix(cut)))
            client.urlProtocolDidFinishLoading(self)
            return
        }
        client.urlProtocol(self, didLoad: Data(slice))
        client.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private func stubSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubServer.self]
    return URLSession(configuration: configuration)
}

private func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

/// The stub's statics are shared: these tests run one at a time.
@Suite(.serialized) struct DownloaderTests {
    let url = URL(string: "https://stub.test/file")!

    @Test func interruptedDownloadResumesWithRange() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vp-dl-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        StubServer.body = Data((0..<300_000).map { UInt8($0 % 251) })
        StubServer.rangesSeen = []
        StubServer.ignoreRange = false
        StubServer.cutAfter = 100_000
        let target = dir.appendingPathComponent("image.iso")
        await #expect(throws: DownloadError.incomplete(received: 100_000, expected: 300_000)) {
            try await Downloader.download(url, to: target, sha256: sha(StubServer.body), session: stubSession())
        }
        let partial = target.appendingPathExtension("partial")
        #expect((try FileManager.default.attributesOfItem(atPath: partial.path)[.size] as? Int) == 100_000)

        let done = try await Downloader.download(url, to: target, sha256: sha(StubServer.body), session: stubSession())
        #expect(StubServer.rangesSeen == ["bytes=100000-"])
        #expect(try Data(contentsOf: done) == StubServer.body)
        #expect(!FileManager.default.fileExists(atPath: partial.path))
    }

    @Test func serverIgnoringRangeRestartsCleanly() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vp-dl-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        StubServer.body = Data((0..<50_000).map { UInt8($0 % 7) })
        StubServer.cutAfter = 10_000
        StubServer.ignoreRange = false
        let target = dir.appendingPathComponent("image.iso")
        _ = try? await Downloader.download(url, to: target, sha256: sha(StubServer.body), session: stubSession())
        StubServer.ignoreRange = true
        let done = try await Downloader.download(url, to: target, sha256: sha(StubServer.body), session: stubSession())
        #expect(try Data(contentsOf: done) == StubServer.body)
        StubServer.ignoreRange = false
    }

    @Test func checksumMismatchDiscardsTheDownload() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vp-dl-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        StubServer.body = Data(repeating: 1, count: 1000)
        StubServer.cutAfter = nil
        let target = dir.appendingPathComponent("image.iso")
        await #expect(throws: DownloadError.self) {
            try await Downloader.download(url, to: target, sha256: String(repeating: "0", count: 64), session: stubSession())
        }
        #expect(!FileManager.default.fileExists(atPath: target.path))
        #expect(!FileManager.default.fileExists(atPath: target.appendingPathExtension("partial").path))
        await #expect(throws: DownloadError.insecureURL) {
            try await Downloader.download(URL(string: "http://stub.test/file")!, to: target, sha256: sha(StubServer.body))
        }
    }
}

/// A small ISO in `dir` with `EFI/<boot>/<loader>` (none when nil).
private func makeISO(in dir: URL, _ name: String, loader: String?, boot: String = "BOOT") throws -> URL {
    let tree = dir.appendingPathComponent("\(name)-tree")
    try FileManager.default.createDirectory(at: tree.appendingPathComponent("EFI/\(boot)"), withIntermediateDirectories: true)
    if let loader { try Data("efi".utf8).write(to: tree.appendingPathComponent("EFI/\(boot)/\(loader)")) }
    let iso = dir.appendingPathComponent("\(name).iso")
    let child = try ChildSpawner.spawn(
        URL(fileURLWithPath: "/usr/bin/hdiutil"),
        .init(arguments: ["makehybrid", "-quiet", "-iso", "-joliet", "-o", iso.path, tree.path]))
    var status: Int32 = 0
    waitpid(child.pid, &status, 0)
    return iso
}

private func temporaryDirectory() throws -> URL {
    let dir = URL(fileURLWithPath: "/tmp/vp-iso-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@Test func isoInspectorRecognisesArm64Media() throws {
    let dir = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    #expect(ISOInspector.inspect(try makeISO(in: dir, "arm", loader: "BOOTAA64.EFI")) == .arm64)
    #expect(ISOInspector.inspect(try makeISO(in: dir, "x86", loader: "BOOTX64.EFI")) == .notArm64)
    #expect(ISOInspector.inspect(dir.appendingPathComponent("missing.iso")) == .unreadable)
}

/// Debian's arm64 netinst has a partition table in its system area (a hybrid ISO): macOS will not mount it
/// ("no mountable file systems"), so the wizard said "unreadable". Its ISO 9660 tree is read without mounting.
@Test func isoInspectorReadsHybridMediaMacOSCannotMount() throws {
    let dir = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    func hybrid(_ name: String, loader: String) throws -> URL {
        let iso = try makeISO(in: dir, name, loader: loader, boot: "boot")
        let file = try FileHandle(forUpdating: iso)
        try file.seek(toOffset: 446)  // an MBR with one EFI system partition, as hybrid ISOs carry
        try file.write(contentsOf: [0x00, 0, 0, 0, 0xEF, 0, 0, 0, 64, 0, 0, 0, 8, 0, 0, 0])
        try file.seek(toOffset: 510)
        try file.write(contentsOf: [0x55, 0xAA])
        try file.close()
        return iso
    }
    #expect(ISOInspector.inspect(try hybrid("debian", loader: "bootaa64.efi")) == .arm64)
    #expect(ISOInspector.inspect(try hybrid("amd64", loader: "bootx64.efi")) == .notArm64)
    let notISO = dir.appendingPathComponent("zeros.iso")
    try Data(count: 64 << 10).write(to: notISO)
    #expect(ISOInspector.inspect(notISO) == .unreadable)
}

@Test func linuxInstallAttachesOnlyArm64Media() throws {
    let dir = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let config = VMConfigV1(VMConfigFields.new(name: "L", os: .linux, macAddress: MachineIdentity.randomMACAddress()))
    let iso = try makeISO(in: dir, "arm", loader: "BOOTAA64.EFI")
    let prepared = try LinuxInstall.prepare(config, iso: iso)
    #expect(prepared.removable.map(\.fields) == [RemovableConfig(id: "install", path: iso.path, bus: .usb)])
    #expect(prepared.install?.media == "install")
    #expect(try LinuxInstall.prepare(prepared, iso: iso).removable.count == 1)  // replaced, not added twice
    #expect(throws: LinuxInstallError.notArm64) {
        try LinuxInstall.prepare(config, iso: try makeISO(in: dir, "x86", loader: "BOOTX64.EFI"))
    }
}

@Test func linuxInstallFinishesOnceTheBootLoaderIsInstalled() throws {
    let dir = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let fresh = VMConfigV1(VMConfigFields.new(name: "L", os: .linux, macAddress: MachineIdentity.randomMACAddress()))
    let bundle = try VMBundle.create(at: dir.appendingPathComponent("L.vmpane"), config: fresh)
    let config = try LinuxInstall.prepare(fresh, iso: try makeISO(in: dir, "arm", loader: "BOOTAA64.EFI"))
    let disk = try bundle.fileURL(relativePath: try #require(config.disks.first).file)
    try DiskImage.createRaw(at: disk, sizeBytes: 64 << 20)
    let variables = bundle.auxDirectory.appendingPathComponent("efi_vars.fd")
    try FileManager.default.createDirectory(at: bundle.auxDirectory, withIntermediateDirectories: true)
    // Blank disk, firmware booted the ISO only: still installing.
    try utf16(#"\EFI\BOOT\BOOTAA64.EFI"#, at: 1).write(to: variables)
    #expect(LinuxInstall.finished(config, bundle: bundle) == nil)
    // Partitioned, but no boot loader yet (the installer is still copying): still installing.
    let handle = try FileHandle(forWritingTo: disk)
    try handle.seek(toOffset: 512)
    try handle.write(contentsOf: Data("EFI PART".utf8))
    try handle.close()
    #expect(LinuxInstall.finished(config, bundle: bundle) == nil)
    // The installer registered its boot loader: done.
    try utf16(#"\EFI\debian\shimaa64.efi"#, at: 1).write(to: variables)
    let done = try #require(LinuxInstall.finished(config, bundle: bundle))
    #expect(done.removable.isEmpty && done.install == nil)
    #expect(LinuxInstall.finished(done, bundle: bundle) == nil)  // not installing any more
}

/// `text` as UTF-16LE after `offset` padding bytes (EFI variable stores do not align strings for us).
private func utf16(_ text: String, at offset: Int) -> Data {
    Data(repeating: 0, count: offset) + text.utf16.reduce(into: Data()) { $0.append(contentsOf: [UInt8($1 & 0xFF), UInt8($1 >> 8)]) }
}

@Test func reinstallingForgetsTheOldBootEntries() throws {
    let dir = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let config = VMConfigV1(VMConfigFields.new(name: "L", os: .linux, macAddress: MachineIdentity.randomMACAddress()))
    let bundle = try VMBundle.create(at: dir.appendingPathComponent("L.vmpane"), config: config)
    let store = bundle.auxDirectory.appendingPathComponent("efi_vars.fd")
    try FileManager.default.createDirectory(at: bundle.auxDirectory, withIntermediateDirectories: true)
    try utf16(#"\EFI\debian\shimaa64.efi"#, at: 0).write(to: store)
    let lock = try #require(try bundle.tryLock(retryingFor: 5))
    defer { lock.release() }
    try LinuxInstall.forgetBootEntries(holding: lock)
    #expect(!FileManager.default.fileExists(atPath: store.path))
    try LinuxInstall.forgetBootEntries(holding: lock)  // nothing to forget: fine
}

/// The wizard shows these to people: sentences, not case names like "unreadable".
@Test func installErrorsReadAsSentences() {
    #expect(ErrorText.readable(LinuxInstallError.unreadable).contains("cannot be read"))
    #expect(ErrorText.readable(LinuxInstallError.notArm64).contains("arm64"))
    #expect(ErrorText.readable(DownloadError.httpStatus(404)).contains("404"))
    #expect(ErrorText.readable(InsufficientSpace(requiredBytes: 30 << 30, availableBytes: 2 << 30)).contains("not enough free disk space"))
}
