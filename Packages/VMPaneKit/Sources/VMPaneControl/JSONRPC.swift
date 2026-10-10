import Foundation
import VMPaneCore

/// JSON-RPC 2.0 request id: an integer or a string (fractional numbers are rejected).
public enum RPCID: Hashable, Sendable, Codable, CustomStringConvertible {
    case int(Int64)
    case string(String)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int64.self) {
            self = .int(value)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .int(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        }
    }

    public var description: String {
        switch self {
        case .int(let value): String(value)
        case .string(let value): value
        }
    }
}

public struct RPCError: Error, Equatable, Sendable, Codable {
    public var code: Int
    public var message: String
    public var data: JSONValue?

    public init(code: Int, message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }

    public init(_ code: ControlErrorCode, _ message: String, data: JSONValue? = nil) {
        self.init(code: code.rawValue, message: message, data: data)
    }

    public var knownCode: ControlErrorCode? { ControlErrorCode(rawValue: code) }
}

/// A request (with an id) or a notification (without).
public struct RPCRequest: Equatable, Sendable {
    public var id: RPCID?
    public var method: String
    public var params: JSONValue?

    public init(id: RPCID?, method: String, params: JSONValue? = nil) {
        self.id = id
        self.method = method
        self.params = params
    }

    public var isNotification: Bool { id == nil }
}

public struct RPCResponse: Equatable, Sendable {
    /// nil only for errors about a request whose id could not be read.
    public var id: RPCID?
    public var outcome: Result<JSONValue, RPCError>

    public init(id: RPCID?, result: JSONValue) {
        self.id = id
        outcome = .success(result)
    }

    public init(id: RPCID?, error: RPCError) {
        self.id = id
        outcome = .failure(error)
    }
}

public enum RPCMessage: Equatable, Sendable {
    case request(RPCRequest)
    case response(RPCResponse)
}

/// One message per line (NDJSON): compact JSON, sorted keys, `\n`-terminated. Batches are not supported.
public enum RPCCodec {
    /// Longest accepted request line, newline excluded. Longer lines get an error and close the connection.
    public static let maxLineBytes = 1 << 20
    /// Longest response or notification a client accepts (screenshots are large).
    public static let maxResponseLineBytes = 64 << 20

    public static func encode(_ message: RPCMessage) throws -> Data {
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
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(JSONValue.object(object))
        data.append(0x0A)
        return data
    }

    /// Decodes one line (without its newline). Failures carry the JSON-RPC error to send back and, when
    /// it could be read, the request id.
    public static func decode(_ line: Data) -> Result<RPCMessage, DecodeFailure> {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: line) else {
            return .failure(DecodeFailure(id: nil, error: RPCError(.parseError, "parse error")))
        }
        if value.isArray {
            return .failure(DecodeFailure(id: nil, error: RPCError(.invalidRequest, "batch requests are not supported")))
        }
        guard let object = value.objectValue else {
            return .failure(DecodeFailure(id: nil, error: RPCError(.invalidRequest, "not an object")))
        }
        if object["method"] != nil, object.keys.contains("id"), object["id"] == .null {
            // A request with id null expects an answer it cannot be matched to: refuse it rather than
            // running it as a notification the client waits on.
            return .failure(DecodeFailure(id: nil, error: RPCError(.invalidRequest, "id must not be null")))
        }
        let id: RPCID?
        switch parseID(object["id"]) {
        case .success(let value): id = value
        case .failure(let failure): return .failure(failure)
        }
        guard object["jsonrpc"] == "2.0" else {
            return .failure(DecodeFailure(id: id, error: RPCError(.invalidRequest, "jsonrpc must be \"2.0\"")))
        }
        if let method = object["method"] {
            return decodeRequest(object, id: id, method: method)
        }
        return decodeResponse(object, id: id)
    }

    private static func parseID(_ value: JSONValue?) -> Result<RPCID?, DecodeFailure> {
        switch value {
        case nil, .null?: .success(nil)
        case .int(let id)?: .success(.int(id))
        case .string(let id)?: .success(.string(id))
        default: .failure(DecodeFailure(id: nil, error: RPCError(.invalidRequest, "id must be an integer or a string")))
        }
    }

    private static func decodeRequest(_ object: [String: JSONValue], id: RPCID?, method: JSONValue) -> Result<RPCMessage, DecodeFailure> {
        guard case .string(let name) = method, !name.isEmpty else {
            return .failure(DecodeFailure(id: id, error: RPCError(.invalidRequest, "method must be a string")))
        }
        let params = object["params"]
        if let params, params.objectValue == nil, !params.isArray {
            return .failure(DecodeFailure(id: id, error: RPCError(.invalidRequest, "params must be an object or an array")))
        }
        return .success(.request(RPCRequest(id: id, method: name, params: params)))
    }

    private static func decodeResponse(_ object: [String: JSONValue], id: RPCID?) -> Result<RPCMessage, DecodeFailure> {
        if let result = object["result"] {
            return .success(.response(RPCResponse(id: id, result: result)))
        }
        if let error = object["error"]?.objectValue, let code = error["code"]?.intValue, let message = error["message"]?.stringValue {
            return .success(.response(RPCResponse(id: id, error: RPCError(code: Int(code), message: message, data: error["data"]))))
        }
        return .failure(DecodeFailure(id: id, error: RPCError(.invalidRequest, "neither a request nor a response")))
    }

    public struct DecodeFailure: Error, Equatable, Sendable {
        public var id: RPCID?
        public var error: RPCError
    }
}

extension LineFramer {
    /// A framer for JSON-RPC requests (`RPCCodec.maxLineBytes`).
    public init() { self.init(maxLineBytes: RPCCodec.maxLineBytes) }
}

extension RPCID {
    var jsonValue: JSONValue {
        switch self {
        case .int(let value): .int(value)
        case .string(let value): .string(value)
        }
    }
}

extension JSONValue {
    var isArray: Bool {
        if case .array = self { return true }
        return false
    }
}
