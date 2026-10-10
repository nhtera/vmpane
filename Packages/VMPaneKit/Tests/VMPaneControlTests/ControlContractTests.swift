import Foundation
import Testing
import VMPaneCore

@testable import VMPaneControl

/// `docs/control-protocol.md`, read from the source tree.
private func contractDoc(file: String = #filePath) throws -> String {
    let root = URL(fileURLWithPath: file).deletingLastPathComponent()  // Tests/VMPaneControlTests
        .deletingLastPathComponent().deletingLastPathComponent()  // Packages/VMPaneKit
        .deletingLastPathComponent().deletingLastPathComponent()  // repo root
    return try String(contentsOf: root.appendingPathComponent("docs/control-protocol.md"), encoding: .utf8)
}

/// Rows of the table between `<!-- contract:<name>:begin -->` and `…:end -->`, as trimmed cells.
private func table(_ name: String, in doc: String) throws -> [[String]] {
    let begin = try #require(doc.range(of: "<!-- contract:\(name):begin -->"))
    let end = try #require(doc.range(of: "<!-- contract:\(name):end -->"))
    return doc[begin.upperBound..<end.lowerBound]
        .split(separator: "\n")
        .map { line in
            // Split on unescaped pipes only (`\|` appears inside cells).
            line.replacingOccurrences(of: "\\|", with: "\u{1}")
                .split(separator: "|", omittingEmptySubsequences: false)
                .map { $0.replacingOccurrences(of: "\u{1}", with: "|").trimmingCharacters(in: .whitespaces) }
        }
        .filter { $0.count > 2 && $0[1].hasPrefix("`") }
        .map { Array($0[1..<($0.count - 1)]) }
}

private func name(_ cell: String) -> String { cell.trimmingCharacters(in: CharacterSet(charactersIn: "`")) }

@Test func docMethodsMatchCodeAndPolicy() throws {
    let rows = try table("methods", in: contractDoc())
    let docMethods = rows.map { name($0[0]) }
    #expect(Set(docMethods).count == docMethods.count, "duplicate rows")
    #expect(Set(docMethods) == Set(ControlMethod.allCases.map(\.rawValue)))
    #expect(Set(docMethods) == Set(ControlMethodPolicy.table.keys))
    for row in rows {
        let rule = ControlMethodPolicy.table[name(row[0])]
        #expect(rule?.summary == row[3], "\(row[0]): doc says \(row[3]), code says \(rule?.summary ?? "nothing")")
    }
}

@Test func docNotificationsMatchCode() throws {
    let rows = try table("notifications", in: contractDoc())
    #expect(Set(rows.map { name($0[0]) }) == Set(ControlNotification.allCases.map(\.rawValue)))
}

@Test func docErrorCodesMatchCode() throws {
    let doc = try contractDoc()
    for code in ControlErrorCode.allCases where code.rawValue > -32100 {
        #expect(doc.contains("| \(code.rawValue) | \(code) |"), "\(code) missing from the error table")
    }
}
