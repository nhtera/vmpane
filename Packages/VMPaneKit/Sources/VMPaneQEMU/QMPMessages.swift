import Foundation
import VMPaneCore

/// One message from QEMU on a QMP connection, decoded strictly: anything that is not exactly a greeting,
/// an event, a success or an error answer is a protocol violation.
enum QMPMessage: Equatable {
    case greeting(JSONValue)
    case event(QMPEvent)
    /// `id` is nil when QEMU could not read the request's id.
    case success(id: Int64?, JSONValue)
    case failure(id: Int64?, errorClass: String, description: String)

    static func decode(_ line: Data) throws -> QMPMessage {
        guard case .object(let object) = try JSONDecoder().decode(JSONValue.self, from: line) else {
            throw QMPError.protocolViolation("message is not an object")
        }
        let id = try object["id"].map(Self.id)
        if let greeting = object["QMP"] {
            guard object.count == 1, greeting.objectValue != nil else { throw QMPError.protocolViolation("malformed greeting") }
            return .greeting(.object(object))
        }
        if let name = object["event"] {
            guard let name = name.stringValue, !name.isEmpty else { throw QMPError.protocolViolation("event without a name") }
            let data = object["data"] ?? .object([:])
            guard data.objectValue != nil else { throw QMPError.protocolViolation("event \(name) data is not an object") }
            return .event(QMPEvent(name: name, data: data, timestamp: timestamp(object["timestamp"])))
        }
        if let value = object["return"] {
            return .success(id: id, value)
        }
        if let error = object["error"] {
            guard let errorClass = error["class"]?.stringValue, let description = error["desc"]?.stringValue else {
                throw QMPError.protocolViolation("malformed error")
            }
            return .failure(id: id, errorClass: errorClass, description: description)
        }
        throw QMPError.protocolViolation("unknown message")
    }

    /// We only send integer ids.
    private static func id(_ value: JSONValue) throws -> Int64 {
        guard let id = value.intValue else { throw QMPError.protocolViolation("unexpected id") }
        return id
    }

    private static func timestamp(_ value: JSONValue?) -> Date? {
        guard let seconds = value?["seconds"]?.intValue, let micros = value?["microseconds"]?.intValue else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(seconds) + TimeInterval(micros) / 1e6)
    }
}
