import Foundation

/// One agent-protocol frame: `u32 BE length | u8 type | payload`, `length` counting the type byte and the
/// payload. Mirror of `vmpane-agent-proto::frame`; `agent/proto/vectors/frames.json` keeps the two in step.
///
/// Stream ids are never 0. Whoever names a stream in a request allocates its id: the host odd, the guest even.
public enum AgentFrame: Equatable, Sendable {
    /// One JSON-RPC message, not yet parsed (`AgentCodec.decode`).
    case message(Data)
    case chunk(stream: UInt32, data: Data)
    case end(stream: UInt32, status: StreamStatus)

    public enum StreamStatus: UInt8, Sendable {
        /// All data was sent.
        case ok = 0
        /// The sender failed part way; the data is incomplete.
        case error = 1
        /// The sender or receiver gave up.
        case cancelled = 2
    }

    public static let typeMessage: UInt8 = 0
    public static let typeChunk: UInt8 = 1
    public static let typeEnd: UInt8 = 2
    static let headerLength = 5

    /// True for ids the host allocates (odd).
    public static func isHostStream(_ stream: UInt32) -> Bool { stream % 2 == 1 }

    /// The encoded frame. Throws, producing nothing, when the frame breaks a limit.
    public func encoded() throws(AgentFrameError) -> Data {
        var out = Data()
        switch self {
        case .message(let json):
            guard json.count <= AgentLimits.maxJSONFrame else { throw .tooLarge }
            Self.appendHeader(&out, length: 1 + json.count, type: Self.typeMessage)
            out.append(json)
        case .chunk(let stream, let data):
            guard stream != 0 else { throw .badStream }
            guard !data.isEmpty else { throw .badLength }
            guard data.count <= AgentLimits.maxChunk else { throw .tooLarge }
            Self.appendHeader(&out, length: 5 + data.count, type: Self.typeChunk)
            Self.appendUInt32(&out, stream)
            out.append(data)
        case .end(let stream, let status):
            guard stream != 0 else { throw .badStream }
            Self.appendHeader(&out, length: 6, type: Self.typeEnd)
            Self.appendUInt32(&out, stream)
            out.append(status.rawValue)
        }
        return out
    }

    private static func appendHeader(_ out: inout Data, length: Int, type: UInt8) {
        out.reserveCapacity(4 + length)
        appendUInt32(&out, UInt32(length))
        out.append(type)
    }

    private static func appendUInt32(_ out: inout Data, _ value: UInt32) {
        withUnsafeBytes(of: value.bigEndian) { out.append(contentsOf: $0) }
    }

    /// Checks a header before any payload is buffered.
    static func checkHeader(length: Int, type: UInt8) throws(AgentFrameError) {
        guard length >= 1 else { throw .badLength }
        let payload = length - 1
        switch type {
        case typeMessage:
            if payload > AgentLimits.maxJSONFrame { throw .tooLarge }
        case typeChunk:
            if payload <= 4 { throw .badLength }
            if payload - 4 > AgentLimits.maxChunk { throw .tooLarge }
        case typeEnd:
            if payload != 5 { throw .badLength }
        default:
            throw .badType
        }
    }
}

/// A frame broke the format or a limit. The byte stream is no longer at a frame boundary: drop the connection.
public enum AgentFrameError: String, Error, Sendable {
    case badLength, tooLarge, badType, badStream, badStatus
}

/// Decodes frames from bytes as they arrive. A frame whose header breaks a limit is rejected before its
/// payload is buffered, so a peer can never make the host hold more than one maximal frame.
public struct AgentFrameDecoder: Sendable {
    private var buffer = Data()
    private var offset = 0

    public init() {}

    /// Bytes received but not yet returned as frames.
    public var bufferedCount: Int { buffer.count - offset }

    public mutating func append(_ data: Data) {
        if offset > 0, offset >= buffer.count / 2 {
            buffer.removeSubrange(buffer.startIndex..<buffer.startIndex + offset)
            offset = 0
        }
        buffer.append(data)
    }

    /// The next whole frame, or nil when more bytes are needed.
    public mutating func next() throws(AgentFrameError) -> AgentFrame? {
        let available = bufferedCount
        let base = buffer.startIndex + offset
        if available < AgentFrame.headerLength {
            // A zero length is already wrong with four bytes; reject it without waiting for a type byte.
            if available >= 4, buffer[base..<base + 4].allSatisfy({ $0 == 0 }) { throw .badLength }
            return nil
        }
        let length = Int(readUInt32(at: base))
        let type = buffer[base + 4]
        try AgentFrame.checkHeader(length: length, type: type)
        guard available >= 4 + length else { return nil }
        let payloadStart = base + AgentFrame.headerLength
        let payloadEnd = base + 4 + length
        offset += 4 + length
        switch type {
        case AgentFrame.typeMessage:
            return .message(Data(buffer[payloadStart..<payloadEnd]))
        case AgentFrame.typeChunk:
            let stream = readUInt32(at: payloadStart)
            guard stream != 0 else { throw .badStream }
            return .chunk(stream: stream, data: Data(buffer[payloadStart + 4..<payloadEnd]))
        default:
            let stream = readUInt32(at: payloadStart)
            guard stream != 0 else { throw .badStream }
            guard let status = AgentFrame.StreamStatus(rawValue: buffer[payloadStart + 4]) else { throw .badStatus }
            return .end(stream: stream, status: status)
        }
    }

    private func readUInt32(at index: Int) -> UInt32 {
        buffer[index..<index + 4].reduce(0) { $0 << 8 | UInt32($1) }
    }
}
