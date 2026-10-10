import Foundation
import Testing

@testable import VMPaneCore

@Test func shortIDIsFirstEightLowercaseHexDigits() throws {
    let uuid = try #require(UUID(uuidString: "6F1C2D0E-8E2B-4C3A-9D3E-1A2B3C4D5E6F"))
    #expect(ShortID(uuid).rawValue == "6f1c2d0e")
    #expect(ShortID(rawValue: "6f1c2d0e") != nil)
    #expect(ShortID(rawValue: "6F1C2D0E") == nil)
    #expect(ShortID(rawValue: "6f1c2d0") == nil)
    #expect(ShortID(rawValue: "6f1c2d0g") == nil)
}

@Test func socketPathFitsForAFortyCharacterHome() {
    let home = "/Users/" + String(repeating: "a", count: 40)
    let paths = VMPanePaths(root: URL(fileURLWithPath: home + "/Library/Application Support/VMPane"))
    let socket = paths.socket(for: ShortID(UUID()))
    #expect(socket.path.utf8.count < 104)
    #expect(UnixSocketAddress(socket) == .absolute(socket.path))
}

@Test func overlongSocketPathFallsBackToRelative() {
    let paths = VMPanePaths(root: URL(fileURLWithPath: "/Users/" + String(repeating: "b", count: 80) + "/VMPane"))
    let sid = ShortID(UUID())
    #expect(UnixSocketAddress(paths.socket(for: sid)) == .relative(directory: paths.runDirectory.path, name: "\(sid).sock"))
}

@Test func runFilesAreKeyedByShortID() throws {
    let paths = VMPanePaths(root: URL(fileURLWithPath: "/tmp/vp"))
    let sid = try #require(ShortID(rawValue: "0123abcd"))
    #expect(paths.socket(for: sid).path == "/tmp/vp/run/0123abcd.sock")
    #expect(paths.pidFile(for: sid).path == "/tmp/vp/run/0123abcd.pid")
    #expect(paths.childrenFile(for: sid).path == "/tmp/vp/run/0123abcd.children")
    #expect(paths.childDirectory(for: sid).path == "/tmp/vp/run/0123abcd")
    #expect(paths.runtime(version: "0.1.0").path == "/tmp/vp/runtime/0.1.0")
}

@Test func shortIDCodesAsAString() throws {
    let id = try #require(ShortID(rawValue: "0123abcd"))
    let data = try JSONEncoder().encode(id)
    #expect(String(bytes: data, encoding: .utf8) == "\"0123abcd\"")
    #expect(try JSONDecoder().decode(ShortID.self, from: data) == id)
    #expect(throws: DecodingError.self) { try JSONDecoder().decode(ShortID.self, from: Data("\"XYZ\"".utf8)) }
    #expect(id.description == "0123abcd")
}
