import Foundation

/// Short VM id used in run-directory names: the first 8 hex digits of the VM UUID, lower case.
/// Keeps socket paths short (`sun_path` is 104 bytes).
public struct ShortID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String

    public init(_ uuid: UUID) {
        rawValue = String(uuid.uuidString.lowercased().prefix(8))
    }

    /// Accepts exactly 8 lower-case hex digits.
    public init?(rawValue: String) {
        guard rawValue.count == 8, rawValue.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else { return nil }
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        guard let id = ShortID(rawValue: value) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "not a short id: \(value)"))
        }
        self = id
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue }
}
