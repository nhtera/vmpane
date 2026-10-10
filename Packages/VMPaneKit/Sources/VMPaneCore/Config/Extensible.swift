import Foundation

/// The known fields of a JSON object, listed so unknown keys can be told apart and kept.
public protocol ExtensibleFields: Codable, Sendable, Equatable {
    /// JSON keys this type decodes. Every other key of the object goes to `Extensible.extras`.
    static var knownKeys: Set<String> { get }
}

/// A JSON object with typed known fields plus every unknown key preserved, so a file written by a newer
/// build (same schema version) survives a read-modify-write by this one. Fields are reached directly
/// (`config.cpu.count`) through dynamic member lookup.
@dynamicMemberLookup
public struct Extensible<Fields: ExtensibleFields>: Codable, Sendable, Equatable {
    public var fields: Fields
    public var extras: [String: JSONValue]

    public init(_ fields: Fields, extras: [String: JSONValue] = [:]) {
        self.fields = fields
        self.extras = extras
    }

    public subscript<Value>(dynamicMember keyPath: WritableKeyPath<Fields, Value>) -> Value {
        get { fields[keyPath: keyPath] }
        set { fields[keyPath: keyPath] = newValue }
    }

    public init(from decoder: Decoder) throws {
        fields = try Fields(from: decoder)
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        var extras: [String: JSONValue] = [:]
        for key in container.allKeys where !Fields.knownKeys.contains(key.stringValue) {
            extras[key.stringValue] = try container.decode(JSONValue.self, forKey: key)
        }
        self.extras = extras
    }

    public func encode(to encoder: Encoder) throws {
        try fields.encode(to: encoder)
        var container = encoder.container(keyedBy: AnyCodingKey.self)
        for (key, value) in extras where !Fields.knownKeys.contains(key) {
            try container.encode(value, forKey: AnyCodingKey(key))
        }
    }
}

/// A coding key for arbitrary strings.
public struct AnyCodingKey: CodingKey, Hashable, Sendable {
    public let stringValue: String
    public var intValue: Int? { nil }

    public init(_ string: String) { stringValue = string }
    public init?(stringValue: String) { self.stringValue = stringValue }
    public init?(intValue: Int) { nil }
}
