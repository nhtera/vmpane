import Foundation
import VMPaneCore

/// Typed access to request params and results.
public enum RPCParams {
    /// Decodes `params` (an object) into `T`; missing params decode from `{}`.
    public static func decode<T: Decodable>(_ type: T.Type, from params: JSONValue?) -> Result<T, RPCError> {
        do {
            let data = try JSONEncoder().encode(params ?? .object([:]))
            return .success(try CanonicalJSON.decoder().decode(T.self, from: data))
        } catch {
            return .failure(RPCError(.invalidParams, "invalid params: \(error)"))
        }
    }

    /// Encodes a result value as JSON.
    public static func encode<T: Encodable>(_ value: T) -> Result<JSONValue, RPCError> {
        do {
            let data = try CanonicalJSON.encoder().encode(value)
            return .success(try JSONDecoder().decode(JSONValue.self, from: data))
        } catch {
            return .failure(RPCError(.internalError, "cannot encode result: \(error)"))
        }
    }
}
