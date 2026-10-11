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

/// The drop folder path comes from the guest user's shell and steers a root chown: only a drop folder passes.
@Test func onlyDropFoldersAreAccepted() {
    #expect(HelperController.isDropFolder("/home/u/Desktop/VMPane Drops/2026-10-11 08.00.00", windows: false))
    #expect(HelperController.isDropFolder(#"C:\Users\u\Desktop\VMPane Drops\2026-10-11 08.00.00"#, windows: true))
    for bad in [
        "/", "/etc", "/home/u/Desktop/VMPane Drops/../../..", "home/u/Desktop/VMPane Drops/x", "/x/Desktop/VMPane Drops/", "/a/b/Other/x",
    ] {
        #expect(!HelperController.isDropFolder(bad, windows: false), "\(bad)")
    }
    #expect(
        HelperController.isNumericOwner("1000:1000") && !HelperController.isNumericOwner("root:root")
            && !HelperController.isNumericOwner("0:0 /"))
}
