import Foundation
import Testing

@testable import VMPaneHost

@Test func dropsWalkFoldersAndSkipLinks() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("vp-drop-\(UUID().uuidString.prefix(8))")
    defer { try? FileManager.default.removeItem(at: root) }
    let folder = root.appendingPathComponent("Album")
    try FileManager.default.createDirectory(at: folder.appendingPathComponent("2026"), withIntermediateDirectories: true)
    try Data("abc".utf8).write(to: folder.appendingPathComponent("2026/a.jpg"))
    try Data("readme".utf8).write(to: root.appendingPathComponent("notes.txt"))
    try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("link"), withDestinationURL: URL(fileURLWithPath: "/etc"))
    let (items, skipped) = try HelperController.dropItems([folder, root.appendingPathComponent("notes.txt")])
    #expect(items.map(\.path) == ["Album", "Album/2026", "Album/2026/a.jpg", "notes.txt"])
    #expect(items.map(\.size) == [0, 0, 3, 6])
    #expect(items.filter { $0.source == nil }.map(\.path) == ["Album", "Album/2026"])
    #expect(skipped == ["Album/link"])
}
