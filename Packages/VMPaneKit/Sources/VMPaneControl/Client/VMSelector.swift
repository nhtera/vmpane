import Foundation
import VMPaneCore

/// Finds the VM a command names: its UUID, its short id (the first 8 hex digits, as `vmpane list` shows), or
/// its name (exact, then ignoring case when that is unambiguous).
public enum VMSelector {
    public enum Failure: Error, Equatable, CustomStringConvertible {
        case notFound(String)
        case ambiguous(String, [String])

        public var description: String {
            switch self {
            case .notFound(let selector): "no VM named or with the id \(selector.debugDescription) (vmpane list shows them)"
            case .ambiguous(let selector, let names):
                "\(selector.debugDescription) matches several VMs (\(names.joined(separator: ", "))): use its id"
            }
        }
    }

    public static func resolve(_ selector: String, in items: [VMLibrary.Item]) throws(Failure) -> VMLibrary.Item {
        let wanted = selector.trimmingCharacters(in: .whitespaces)
        if let uuid = UUID(uuidString: wanted), let item = items.first(where: { $0.id == uuid }) { return item }
        let lower = wanted.lowercased()
        if lower.count >= 4, lower.allSatisfy(\.isHexDigit) {
            let byID = items.filter { $0.id.uuidString.lowercased().hasPrefix(lower) }
            if byID.count == 1 { return byID[0] }
            if byID.count > 1 { throw .ambiguous(selector, byID.map(name)) }
        }
        let exact = items.filter { $0.config?.name == wanted }
        if exact.count == 1 { return exact[0] }
        if exact.count > 1 { throw .ambiguous(selector, exact.map(name)) }
        let folded = items.filter { $0.config?.name.lowercased() == lower }
        if folded.count == 1 { return folded[0] }
        if folded.count > 1 { throw .ambiguous(selector, folded.map(name)) }
        throw .notFound(selector)
    }

    private static func name(_ item: VMLibrary.Item) -> String {
        "\(item.config?.name ?? item.bundle.url.deletingPathExtension().lastPathComponent) (\(ShortID(item.id)))"
    }
}
