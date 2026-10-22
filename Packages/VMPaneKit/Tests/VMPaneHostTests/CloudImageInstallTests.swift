import CryptoKit
import Foundation
import Testing
import VMPaneCore

@testable import VMPaneHost

private let image = ImageCatalog.Image(
    id: "debian-13-cloud", name: "Debian 13", version: "13", build: "t", url: URL(fileURLWithPath: "/nonexistent"),
    sha256: String(repeating: "a", count: 64), sizeBytes: 1, kind: "cloudImage", distro: "debian")

@Test func aCloudImageVMGetsAClonedDiskASeedAndLoopbackSSH() throws {
    let root = URL(fileURLWithPath: "/tmp/vp-cloud-\(UUID().uuidString.prefix(8))", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = VMPanePaths(root: root.appendingPathComponent("s"))
    let ops = LibraryOps(library: VMLibrary(paths: paths), identity: .ui)
    let bundle = try ops.create(name: "Build Box", os: .linux, diskGiB: 1)
    let base = root.appendingPathComponent("base.raw")
    try Data(repeating: 7, count: 1 << 20).write(to: base)
    let lock = try #require(try bundle.tryLock())
    let account = CloudImageInstall.Account(userName: "dev", password: "p4ss-word", sshKey: "ssh-ed25519 AAAA k")
    let config = try CloudImageInstall.apply(try ConfigStore.load(bundle), base: base, image: image, account: account, holding: lock)
    try ConfigStore.save(config, holding: lock)
    lock.release()

    let disk = try bundle.fileURL(relativePath: config.disks[0].file)
    #expect(try disk.resourceValues(forKeys: [.fileSizeKey]).fileSize == 1 << 30, "grown to the VM's size")
    #expect(try FileHandle(forReadingFrom: disk).read(upToCount: 4) == Data([7, 7, 7, 7]), "the image's content")
    #expect(config.install?.cloudInit == "cidata" && config.install?.desktop == nil)
    let seed = try #require(config.removable.first { $0.id == "cidata" })
    #expect(seed.path == bundle.installDirectory.appendingPathComponent("cidata.iso").path && seed.bus == .virtio)
    let userData = try String(contentsOf: bundle.installDirectory.appendingPathComponent("cidata/user-data"), encoding: .utf8)
    #expect(userData.contains("hostname: \"build-box\"") && userData.contains("passwd: \"$6$") && !userData.contains("p4ss-word"))
    let ssh = try #require(config.portForwards.first { $0.guestPort == 22 })
    #expect(ssh.hostAddress == "127.0.0.1" && ssh.hostPort > 0 && ssh.origin == .user)

    // A clone before the first boot is a new machine with its own seed.
    let source = try #require(try bundle.tryLock())
    let clone = try FullClone.clone(holding: source, to: root.appendingPathComponent("Copy.vmpane"), name: "Copy")
    source.release()
    let cloned = try ConfigStore.load(clone)
    #expect(cloned.removable.first { $0.id == "cidata" }?.path == clone.installDirectory.appendingPathComponent("cidata.iso").path)
    let meta = { (b: VMBundle) in try String(contentsOf: b.installDirectory.appendingPathComponent("cidata/meta-data"), encoding: .utf8) }
    #expect(
        try meta(clone) != meta(bundle)
            && FileManager.default.fileExists(atPath: clone.installDirectory.appendingPathComponent("cidata.iso").path))

    // Until the guest tools run, the seed stays.
    #expect(CloudImageInstall.finished(config, bundle: bundle) == nil && !CloudImageInstall.isUsed(bundle))
    // They ran: its data goes at once, its ISO becomes a placeholder the running VM can keep (the config is untouched).
    try CloudImageInstall.consume(bundle)
    #expect(CloudImageInstall.isUsed(bundle))
    #expect(!FileManager.default.fileExists(atPath: bundle.installDirectory.appendingPathComponent("cidata").path))
    #expect(try Data(contentsOf: URL(fileURLWithPath: seed.path)).allSatisfy { $0 == 0 }, "nothing of the seed left")
    // The VM stopped: the device leaves the config, the placeholder goes.
    let done = try #require(CloudImageInstall.finished(config, bundle: bundle))
    #expect(done.install == nil && !done.removable.contains { $0.id == "cidata" })
    #expect(!FileManager.default.fileExists(atPath: seed.path))
    #expect(CloudImageInstall.finished(done, bundle: bundle) == nil)
}

@Test func basesAreRecognizedByTheirOwnPattern() {
    #expect(CloudImageInstall.isBase("debian-13-cloud-0123456789abcdef.raw", of: "debian-13-cloud"))
    #expect(!CloudImageInstall.isBase("debian-13-cloud-minimal-0123456789abcdef.raw", of: "debian-13-cloud"), "another image")
    #expect(!CloudImageInstall.isBase("debian-13-cloud-0123.raw", of: "debian-13-cloud"))
}

@Test func hostNamesComeFromTheVMName() {
    #expect(CloudImageInstall.hostName("My Ubuntu (dev)") == "my-ubuntu-dev")
    #expect(CloudImageInstall.hostName("Ünïcode!") == "n-code")
    #expect(CloudImageInstall.hostName("!!!") == "vmpane")
    #expect(!CloudImageInstall.hostName(String(repeating: "a", count: 62) + " b").hasSuffix("-"))
}

/// Serves a cloud image whose byte 100 was flipped.
final class TamperedImageServer: URLProtocol, @unchecked Sendable {
    static let body: Data = {
        var bytes = Data(repeating: 1, count: 4096)
        bytes[100] ^= 0xFF
        return bytes
    }()
    override static func canInit(with request: URLRequest) -> Bool { request.url?.host == "tampered.test" }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let headers = ["Content-Length": "\(Self.body.count)"]
        guard let url = request.url, let client,
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: headers)
        else { return }
        client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client.urlProtocol(self, didLoad: Self.body)
        client.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// An image that does not match its pinned SHA-256 (one byte flipped) is refused before anything is made of it.
@Test func aTamperedCloudImageIsRefused() async throws {
    let root = URL(fileURLWithPath: "/tmp/vp-tamper-\(UUID().uuidString.prefix(8))", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    var tampered = image
    tampered.url = try #require(URL(string: "https://tampered.test/upstream.qcow2"))
    tampered.sha256 = SHA256.hash(data: Data(repeating: 1, count: 4096)).map { String(format: "%02x", $0) }.joined()
    tampered.sizeBytes = 4096
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [TamperedImageServer.self]
    let cache = ImageCache(directory: root.appendingPathComponent("cache", isDirectory: true))
    do {
        _ = try await CloudImageInstall.base(
            tampered, qemuImg: URL(fileURLWithPath: "/usr/bin/false"), cache: cache, session: URLSession(configuration: configuration))
        Issue.record("a tampered image was taken")
    } catch let error as DownloadError {
        guard case .checksumMismatch = error else { Issue.record("\(error)"); return }
    }
    #expect(!CloudImageInstall.isReady(tampered, cache: cache))
    #expect(!FileManager.default.fileExists(atPath: cache.file(for: tampered).path), "nothing of it is kept")
}
