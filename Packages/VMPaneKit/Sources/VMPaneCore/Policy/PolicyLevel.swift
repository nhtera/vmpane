/// How much an automated client (CLI without the UI grant, MCP) may do with a VM.
/// Ordered: each level includes everything below it.
public enum PolicyLevel: String, Codable, Sendable, CaseIterable, Comparable {
    case off, observe, control, exec, admin

    private var rank: Int {
        switch self {
        case .off: 0
        case .observe: 1
        case .control: 2
        case .exec: 3
        case .admin: 4
        }
    }

    public static func < (lhs: PolicyLevel, rhs: PolicyLevel) -> Bool { lhs.rank < rhs.rank }
}
