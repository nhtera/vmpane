import Foundation
import VMPaneCore

/// What `vmpane` prints: JSON for `--json` (sorted keys, one document), aligned columns for people.
public enum OutputFormatter {
    public static func json(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)).flatMap { String(bytes: $0, encoding: .utf8) } ?? "null"
    }

    /// Columns padded to their widest cell; the last column is not padded.
    public static func table(_ header: [String], _ rows: [[String]]) -> String {
        let all = [header] + rows
        let widths = header.indices.map { column in all.map { $0.indices.contains(column) ? $0[column].count : 0 }.max() ?? 0 }
        return all.map { row in
            row.enumerated().map { column, cell in
                column == row.count - 1 ? cell : cell.padding(toLength: widths[column], withPad: " ", startingAt: 0)
            }.joined(separator: "  ")
        }.joined(separator: "\n")
    }
}
