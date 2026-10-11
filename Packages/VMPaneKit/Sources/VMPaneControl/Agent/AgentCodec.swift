import Foundation
import VMPaneCore

/// JSON-RPC 2.0 messages in agent frames: one object per frame, no batches. Mirror of
/// `vmpane-agent-proto::jsonrpc`; `agent/proto/vectors/messages.json` keeps the two in step.
///
/// `decode` checks, in this order: nesting depth on the raw bytes (before the parser recurses), JSON syntax,
/// string and key lengths, then the JSON-RPC shape. Unknown members are ignored.
public enum AgentCodec {
    public enum DecodeError: String, Error, Sendable {
        /// Not UTF-8 JSON.
        case parse
        /// Nested deeper than `AgentLimits.maxJSONDepth`.
        case depth
        /// A string or key longer than `AgentLimits.maxString`.
        case string
        /// Not a JSON-RPC 2.0 message.
        case invalid
    }

    public static func decode(_ bytes: Data) -> Result<RPCMessage, DecodeError> {
        if exceedsDepth(bytes, max: AgentLimits.maxJSONDepth) { return .failure(.depth) }
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: bytes) else { return .failure(.parse) }
        guard stringsWithinLimit(value) else { return .failure(.string) }
        guard let message = message(from: value) else { return .failure(.invalid) }
        return .success(message)
    }

    /// The frame payload: compact JSON, sorted keys. Throws `string` when a string breaks the limit (the
    /// caller must not send it).
    public static func encode(_ message: RPCMessage) throws(DecodeError) -> Data {
        var object: [String: JSONValue] = ["jsonrpc": "2.0"]
        switch message {
        case .request(let request):
            object["method"] = .string(request.method)
            if let params = request.params { object["params"] = params }
            if let id = request.id { object["id"] = id.jsonValue }
        case .response(let response):
            object["id"] = response.id?.jsonValue ?? .null
            switch response.outcome {
            case .success(let result): object["result"] = result
            case .failure(let error):
                var errorObject: [String: JSONValue] = ["code": .int(Int64(error.code)), "message": .string(error.message)]
                if let data = error.data { errorObject["data"] = data }
                object["error"] = .object(errorObject)
            }
        }
        let value = JSONValue.object(object)
        guard stringsWithinLimit(value) else { throw .string }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { throw .invalid }
        return data
    }

    private static func message(from value: JSONValue) -> RPCMessage? {
        guard let object = value.objectValue, object["jsonrpc"] == "2.0" else { return nil }
        if let method = object["method"] {
            guard case .string(let name) = method else { return nil }
            let params = object["params"]
            switch params {
            case nil, .object?, .array?: break
            default: return nil
            }
            guard let rawID = object["id"] else {
                return .request(RPCRequest(id: nil, method: name, params: params))
            }
            guard let id = requestID(rawID) else { return nil }
            return .request(RPCRequest(id: id, method: name, params: params))
        }
        guard let rawID = object["id"] else { return nil }
        let id: RPCID?
        if rawID == .null {
            id = nil
        } else {
            guard let parsed = requestID(rawID) else { return nil }
            id = parsed
        }
        switch (object["result"], object["error"]) {
        case (let result?, nil):
            guard id != nil else { return nil }
            return .response(RPCResponse(id: id, result: result))
        case (nil, let error?):
            guard let fields = error.objectValue, let code = fields["code"]?.intValue, let code32 = Int32(exactly: code),
                let message = fields["message"]?.stringValue
            else { return nil }
            return .response(RPCResponse(id: id, error: RPCError(code: Int(code32), message: message, data: fields["data"])))
        default:
            return nil
        }
    }

    private static func requestID(_ value: JSONValue) -> RPCID? {
        switch value {
        case .int(let id): .int(id)
        case .string(let id): .string(id)
        default: nil
        }
    }

    /// True when arrays and objects nest deeper than `max` (top level = 1). Scans raw bytes, skipping strings.
    static func exceedsDepth(_ bytes: Data, max: Int) -> Bool {
        var depth = 0
        var inString = false
        var escaped = false
        for byte in bytes {
            if inString {
                if escaped {
                    escaped = false
                } else if byte == UInt8(ascii: "\\") {
                    escaped = true
                } else if byte == UInt8(ascii: "\"") {
                    inString = false
                }
                continue
            }
            switch byte {
            case UInt8(ascii: "\""): inString = true
            case UInt8(ascii: "["), UInt8(ascii: "{"):
                depth += 1
                if depth > max { return true }
            case UInt8(ascii: "]"), UInt8(ascii: "}"): depth = Swift.max(0, depth - 1)
            default: break
            }
        }
        return false
    }

    private static func stringsWithinLimit(_ value: JSONValue) -> Bool {
        switch value {
        case .string(let text): text.utf8.count <= AgentLimits.maxString
        case .array(let items): items.allSatisfy(stringsWithinLimit)
        case .object(let object): object.allSatisfy { $0.key.utf8.count <= AgentLimits.maxString && stringsWithinLimit($0.value) }
        default: true
        }
    }
}
