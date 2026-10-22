// A named pasteboard for scenarios that test the window's clipboard sharing (the helper uses it in place of the
// Mac's, with VMPANE_TEST_PASTEBOARD): never the user's clipboard.
// Usage: pasteboard <name> get                  one JSON object: {count, text, html, rtf, files}
//        pasteboard <name> set-files <path>...  file URLs, and their names as text (as Finder copies)
//        pasteboard <name> release              (compiled by it_swift_tool in common.sh)
import AppKit

let arguments = CommandLine.arguments
guard arguments.count >= 3 else {
    FileHandle.standardError.write(Data("usage: pasteboard <name> get | set-files <path>... | release\n".utf8))
    exit(2)
}
let board = NSPasteboard(name: .init(arguments[1]))
switch arguments[2] {
case "get":
    let files = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    let state: [String: Any] = [
        "count": board.changeCount, "text": board.string(forType: .string) ?? NSNull(),
        "html": board.string(forType: .html) ?? NSNull(), "rtf": board.data(forType: .rtf).flatMap { String(data: $0, encoding: .utf8) } ?? NSNull(),
        "files": files.map(\.path),
    ]
    let json = try JSONSerialization.data(withJSONObject: state, options: [.sortedKeys])
    print(String(decoding: json, as: UTF8.self))
case "set-files":
    let urls = arguments.dropFirst(3).map { URL(fileURLWithPath: $0) }
    board.clearContents()
    board.writeObjects(urls as [NSURL])
    board.setString(urls.map(\.lastPathComponent).joined(separator: "\r"), forType: .string)
case "release":
    board.releaseGlobally()
default:
    exit(2)
}
