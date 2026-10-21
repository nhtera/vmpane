import Foundation
import VMPaneCore

/// What a tool hands back: content blocks (text, images), optional structured content, and whether it failed.
public struct ToolResult: Sendable {
    public var content: [JSONValue]
    public var structured: JSONValue?
    public var isError: Bool

    public init(content: [JSONValue], structured: JSONValue? = nil, isError: Bool = false) {
        self.content = content
        self.structured = structured
        self.isError = isError
    }

    public init(text: String, structured: JSONValue? = nil, isError: Bool = false) {
        self.init(content: [["type": "text", "text": .string(text)]], structured: structured, isError: isError)
    }

    var json: JSONValue {
        var result: [String: JSONValue] = ["content": .array(content)]
        if let structured { result["structuredContent"] = structured }
        if isError { result["isError"] = true }
        return .object(result)
    }
}

/// A failure the model should read (a refused policy, a VM that is not running): returned with `isError`.
public struct ToolFailure: Error, Sendable {
    public let message: String
    /// The helper's error code and data, when the failure is its answer.
    public let code: Int?
    public let data: JSONValue?

    public init(_ message: String, code: Int? = nil, data: JSONValue? = nil) {
        self.message = message
        self.code = code
        self.data = data
    }
}

/// What a tool's handler gets besides its arguments.
public struct ToolContext: Sendable {
    /// The client's claimed name, for audit and snapshot names.
    public let client: String?
    /// Reports progress when the client asked for it (`progressToken`).
    public let progress: @Sendable (_ progress: Double, _ total: Double?, _ message: String?) async -> Void
}

/// One tool: its name, what the model reads about it, its argument schema and annotations, and its handler.
public struct Tool: Sendable {
    public let name: String
    public let description: String
    public let inputSchema: JSONValue
    /// `readOnlyHint`, `destructiveHint`, `idempotentHint`, `openWorldHint`.
    public let annotations: JSONValue
    public let handler: @Sendable (JSONValue, ToolContext) async throws -> ToolResult

    public init(
        _ name: String, _ description: String, schema: JSONValue, annotations: JSONValue = [:],
        handler: @escaping @Sendable (JSONValue, ToolContext) async throws -> ToolResult
    ) {
        self.name = name
        self.description = description
        inputSchema = schema
        self.annotations = annotations
        self.handler = handler
    }

    var definition: JSONValue {
        ["name": .string(name), "description": .string(description), "inputSchema": inputSchema, "annotations": annotations]
    }
}

/// The tools, in a fixed order (`tools/list` is deterministic).
public struct ToolRegistry: Sendable {
    public let tools: [Tool]

    public init(_ tools: [Tool]) {
        self.tools = tools
    }

    var definitions: [JSONValue] { tools.map(\.definition) }

    func tool(_ name: String) -> Tool? { tools.first { $0.name == name } }
}

/// JSON Schema helpers for tool arguments.
enum Schema {
    static func object(_ properties: [String: JSONValue], required: [String] = []) -> JSONValue {
        [
            "type": "object", "properties": .object(properties), "required": .array(required.map { .string($0) }),
            "additionalProperties": false,
        ]
    }

    static func string(_ description: String, enum values: [String]? = nil) -> JSONValue {
        var schema: [String: JSONValue] = ["type": "string", "description": .string(description)]
        if let values { schema["enum"] = .array(values.map { .string($0) }) }
        return .object(schema)
    }

    static func number(_ description: String, minimum: Double? = nil) -> JSONValue {
        var schema: [String: JSONValue] = ["type": "number", "description": .string(description)]
        if let minimum { schema["minimum"] = .double(minimum) }
        return .object(schema)
    }

    static func integer(_ description: String, minimum: Int? = nil, maximum: Int? = nil) -> JSONValue {
        var schema: [String: JSONValue] = ["type": "integer", "description": .string(description)]
        if let minimum { schema["minimum"] = .int(Int64(minimum)) }
        if let maximum { schema["maximum"] = .int(Int64(maximum)) }
        return .object(schema)
    }

    static func boolean(_ description: String) -> JSONValue { ["type": "boolean", "description": .string(description)] }

    static func array(_ description: String, items: JSONValue, maxItems: Int? = nil) -> JSONValue {
        var schema: [String: JSONValue] = ["type": "array", "description": .string(description), "items": items]
        if let maxItems { schema["maxItems"] = .int(Int64(maxItems)) }
        return .object(schema)
    }

    static let vm: JSONValue = string("The VM: its name, id or short id (vm_list shows them).")
}
