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

@Test func isoInspectorRecognisesArm64Media() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vp-iso-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    func makeISO(_ name: String, loader: String?) throws -> URL {
        let tree = dir.appendingPathComponent("\(name)-tree")
        try FileManager.default.createDirectory(at: tree.appendingPathComponent("EFI/BOOT"), withIntermediateDirectories: true)
        if let loader { try Data("efi".utf8).write(to: tree.appendingPathComponent("EFI/BOOT/\(loader)")) }
        let iso = dir.appendingPathComponent("\(name).iso")
        let child = try ChildSpawner.spawn(
            URL(fileURLWithPath: "/usr/bin/hdiutil"),
            .init(arguments: ["makehybrid", "-quiet", "-iso", "-joliet", "-o", iso.path, tree.path]))
        var status: Int32 = 0
        waitpid(child.pid, &status, 0)
        return iso
    }
    #expect(ISOInspector.inspect(try makeISO("arm", loader: "BOOTAA64.EFI")) == .arm64)
    #expect(ISOInspector.inspect(try makeISO("x86", loader: "BOOTX64.EFI")) == .notArm64)
    #expect(ISOInspector.inspect(dir.appendingPathComponent("missing.iso")) == .unreadable)
}
