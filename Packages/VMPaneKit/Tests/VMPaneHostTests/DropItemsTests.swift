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

/// The folder path comes from the guest user's shell and steers a root chown: only a folder of the place asked for
/// passes (a drop's, or the clipboard's staging folder).
@Test func onlyTheGuestFoldersVMPaneMakesAreAccepted() {
    #expect(HelperController.isGuestFolder("/home/u/Desktop/VMPane Drops/2026-10-11 08.00.00", place: .drop, windows: false))
    #expect(HelperController.isGuestFolder(#"C:\Users\u\Desktop\VMPane Drops\2026-10-11 08.00.00"#, place: .drop, windows: true))
    #expect(
        HelperController.isGuestFolder("/Users/u/Library/Caches/VMPane Clipboard/2026-10-11 08.00.00", place: .clipboard, windows: false))
    #expect(
        HelperController.isGuestFolder(
            #"C:\Users\u\AppData\Local\Temp\VMPane Clipboard\2026-10-11 08.00.00"#, place: .clipboard, windows: true))
    #expect(!HelperController.isGuestFolder("/home/u/Desktop/VMPane Drops/2026-10-11 08.00.00", place: .clipboard, windows: false))
    for bad in [
        "/", "/etc", "/home/u/Desktop/VMPane Drops/../../..", "home/u/Desktop/VMPane Drops/x", "/x/Desktop/VMPane Drops/", "/a/b/Other/x",
    ] {
        #expect(!HelperController.isGuestFolder(bad, place: .drop, windows: false), "\(bad)")
    }
    #expect(
        HelperController.isNumericOwner("1000:1000") && !HelperController.isNumericOwner("root:root")
            && !HelperController.isNumericOwner("0:0 /"))
}

/// A guest folder's listing: `d` or `f`, then the path as base64 UTF-8; other lines are dropped.
@Test func guestFolderListingsAreReadByLine() {
    let line = { (kind: String, path: String) in kind + Data(path.utf8).base64EncodedString() }
    let listing = [line("d", "Album"), line("f", "Album/ünï 1.jpg"), "junk", line("x", "y"), "f", line("f", "a/b\nc")]
        .joined(separator: "\r\n")
    #expect(
        HelperController.guestEntries(listing) == [
            .init(path: "Album", isFolder: true), .init(path: "Album/ünï 1.jpg", isFolder: false), .init(path: "a/b\nc", isFolder: false),
        ])
}
