import Foundation
import Testing

@testable import VMPaneCore

/// A fresh temp directory per test, removed afterwards.
func withTempDirectory<T>(_ body: (URL) throws -> T) throws -> T {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vmpane-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    return try body(dir)
}

@Test func durableWriteCreatesAndReplacesWithOwnerOnlyMode() throws {
    try withTempDirectory { dir in
        let file = dir.appendingPathComponent("config.json")
        try DurableWrite.write(Data("one".utf8), to: file)
        try DurableWrite.write(Data("two".utf8), to: file)
        #expect(try String(contentsOf: file, encoding: .utf8) == "two")
        let mode = try #require(FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int)
        #expect(mode == 0o600)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["config.json"])
    }
}

@Test func durableWriteFailsCleanlyForMissingDirectory() throws {
    try withTempDirectory { dir in
        #expect(throws: POSIXError.self) {
            try DurableWrite.write(Data(), to: dir.appendingPathComponent("missing/config.json"))
        }
    }
}
