import Darwin
import Foundation
import Testing

@testable import VMPaneHost

private func temporaryRoot() throws -> URL {
    let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("vp-sink-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func write(_ sink: HostFileSink, _ path: String, _ text: String = "x") throws -> URL {
    let (handle, url) = try sink.create(path, expectedBytes: Int64(text.utf8.count))
    try handle.write(contentsOf: Data(text.utf8))
    try handle.close()
    return url
}

@Test(arguments: ["", ".", "..", "a/..", "../x", "a\u{0}b", "a\nb", "x:y", "a\\b", String(repeating: "é", count: 200)])
func hostileNamesAreRefused(_ name: String) throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let sink = HostFileSink(root: root.appendingPathComponent("vm"))
    #expect(throws: HostFileSink.Failure.self) { try write(sink, name) }
    let outside = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0 != "vm" }
    #expect(outside.isEmpty, "nothing lands outside the VM's folder")
}

@Test func filesLandInTheirFolderQuarantinedAndNeverOverwrite() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let sink = HostFileSink(root: root.appendingPathComponent("vm"))
    let first = try write(sink, "report.pdf", "one")
    let second = try write(sink, "report.pdf", "two")
    let nested = try write(sink, "photos/2026/cafe\u{301}.jpg")
    #expect(first.lastPathComponent == "report.pdf" && second.lastPathComponent == "report 2.pdf")
    #expect(try String(contentsOf: first, encoding: .utf8) == "one", "an existing file is not overwritten")
    #expect(nested.path.hasSuffix("vm/photos/2026/caf\u{e9}.jpg"), "names are NFC")
    #expect(getxattr(first.path, "com.apple.quarantine", nil, 0, 0, 0) > 0)
}

/// A symlink in the destination (planted by anyone) cannot send a write elsewhere.
@Test func symlinksInTheDestinationAreNotFollowed() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let elsewhere = root.appendingPathComponent("elsewhere")
    try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
    let vm = root.appendingPathComponent("vm")
    try FileManager.default.createDirectory(at: vm, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: vm.appendingPathComponent("docs"), withDestinationURL: elsewhere)
    try FileManager.default.createSymbolicLink(
        at: vm.appendingPathComponent("note.txt"), withDestinationURL: elsewhere.appendingPathComponent("n"))
    let sink = HostFileSink(root: vm)
    #expect(throws: HostFileSink.Failure.self) { try write(sink, "docs/a.txt") }
    let note = try write(sink, "note.txt")
    #expect(note.lastPathComponent == "note 2.txt", "a link with the name counts as taken, not as a way through")
    #expect(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path).isEmpty)
}

@Test func budgetsCapFilesAndBytes() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let sink = HostFileSink(root: root.appendingPathComponent("vm"), maxFiles: 2, maxBytes: 10)
    _ = try write(sink, "a")
    #expect(throws: HostFileSink.Failure.tooLarge(10)) { try sink.reserve(bytes: 10) }
    _ = try write(sink, "b")
    #expect(throws: HostFileSink.Failure.tooMany(2)) { try write(sink, "c") }
}
