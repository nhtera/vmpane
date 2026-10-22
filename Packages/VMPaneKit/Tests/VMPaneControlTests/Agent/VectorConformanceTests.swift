import Foundation
import Testing
import VMPaneCore

@testable import VMPaneControl

/// The Swift agent codec against the vectors and schema generated from the Rust types (`agent/proto`).
private func proto(_ path: String, file: String = #filePath) throws -> JSONValue {
    let root = URL(fileURLWithPath: file).deletingLastPathComponent()  // Tests/VMPaneControlTests/Agent
        .deletingLastPathComponent().deletingLastPathComponent()  // Tests
        .deletingLastPathComponent().deletingLastPathComponent()  // Packages
        .deletingLastPathComponent()  // repo root
    let data = try Data(contentsOf: root.appendingPathComponent("agent/proto/\(path)"))
    return try JSONDecoder().decode(JSONValue.self, from: data)
}

private func cases(_ path: String) throws -> [JSONValue] {
    guard case .array(let cases)? = try proto(path)["cases"] else { throw VectorError.malformed(path) }
    return cases
}

private enum VectorError: Error { case malformed(String) }

private func string(_ value: JSONValue, _ key: String) throws -> String {
    guard let text = value[key]?.stringValue else { throw VectorError.malformed(key) }
    return text
}

private func int(_ value: JSONValue?) throws -> Int64 {
    guard let number = value?.intValue else { throw VectorError.malformed("integer") }
    return number
}

private func bytes(hex: String) throws -> Data {
    var data = Data()
    var index = hex.startIndex
    while index < hex.endIndex {
        let next = hex.index(index, offsetBy: 2)
        guard let byte = UInt8(hex[index..<next], radix: 16) else { throw VectorError.malformed(hex) }
        data.append(byte)
        index = next
    }
    return data
}

private func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

private func describe(_ frame: AgentFrame) -> JSONValue {
    switch frame {
    case .message(let json): ["type": "message", "json": .string(String(bytes: json, encoding: .utf8) ?? "<not UTF-8>")]
    case .chunk(let stream, let data): ["type": "chunk", "stream": .int(Int64(stream)), "hex": .string(hex(data))]
    case .end(let stream, let status):
        ["type": "end", "stream": .int(Int64(stream)), "status": .string(["ok", "error", "cancelled"][Int(status.rawValue)])]
    }
}

@Test func frameVectors() throws {
    for vector in try cases("vectors/frames.json") {
        let name = vector["name"]?.stringValue ?? "?"
        let input = try bytes(hex: string(vector, "hex"))
        // Feed all at once and one byte at a time: the result must not depend on how bytes arrive.
        for chunking in [input.count, 1] {
            var decoder = AgentFrameDecoder()
            var frames: [JSONValue] = []
            var failure: JSONValue = .null
            var offset = 0
            feeding: while offset < input.count {
                decoder.append(input[offset..<min(offset + max(chunking, 1), input.count)])
                offset += max(chunking, 1)
                do {
                    while let frame = try decoder.next() { frames.append(describe(frame)) }
                } catch {
                    failure = .string(error.rawValue)
                    break feeding
                }
            }
            #expect(JSONValue.array(frames) == vector["frames"], "\(name)")
            #expect(failure == vector["error"], "\(name)")
            if failure == .null {
                #expect(JSONValue.int(Int64(decoder.bufferedCount)) == vector["remaining"], "\(name)")
            }
        }
    }
}

@Test func validFramesEncodeToTheVectorBytes() throws {
    for vector in try cases("vectors/frames.json") where vector["error"] == .null && vector["remaining"] == 0 {
        var encoded = Data()
        guard case .array(let frames)? = vector["frames"] else { continue }
        for frame in frames {
            switch frame["type"]?.stringValue {
            case "message": encoded.append(try AgentFrame.message(Data(string(frame, "json").utf8)).encoded())
            case "chunk":
                let stream = UInt32(try int(frame["stream"]))
                encoded.append(try AgentFrame.chunk(stream: stream, data: bytes(hex: string(frame, "hex"))).encoded())
            default:
                let statuses: [String: AgentFrame.StreamStatus] = ["ok": .ok, "error": .error, "cancelled": .cancelled]
                let status = try #require(statuses[string(frame, "status")])
                encoded.append(try AgentFrame.end(stream: UInt32(try int(frame["stream"])), status: status).encoded())
            }
        }
        #expect(hex(encoded) == vector["hex"]?.stringValue, "\(vector["name"]?.stringValue ?? "?")")
    }
}

@Test func encoderRefusesWhatTheDecoderRejects() {
    #expect(throws: AgentFrameError.badLength) { try AgentFrame.chunk(stream: 1, data: Data()).encoded() }
    #expect(throws: AgentFrameError.badStream) { try AgentFrame.end(stream: 0, status: .ok).encoded() }
    #expect(throws: AgentFrameError.tooLarge) { try AgentFrame.message(Data(count: AgentLimits.maxJSONFrame + 1)).encoded() }
    #expect(throws: AgentFrameError.tooLarge) { try AgentFrame.chunk(stream: 1, data: Data(count: AgentLimits.maxChunk + 1)).encoded() }
}

private func expectation(for result: Result<RPCMessage, AgentCodec.DecodeError>) -> JSONValue {
    switch result {
    case .failure(let error): return ["kind": "error", "error": .string(error.rawValue)]
    case .success(.request(let request)):
        if let id = request.id {
            return ["kind": "request", "id": id.jsonValue, "method": .string(request.method), "hasParams": .bool(request.params != nil)]
        }
        return ["kind": "notification", "method": .string(request.method), "hasParams": .bool(request.params != nil)]
    case .success(.response(let response)):
        let id = response.id?.jsonValue ?? .null
        switch response.outcome {
        case .success: return ["kind": "response", "id": id, "ok": true]
        case .failure(let error): return ["kind": "response", "id": id, "ok": false, "errorCode": .int(Int64(error.code))]
        }
    }
}

@Test func messageVectors() throws {
    for vector in try cases("vectors/messages.json") {
        let input: Data
        if let text = vector["json"]?.stringValue {
            let pad = Int(vector["pad"]?.intValue ?? 0)
            input = Data(text.replacingOccurrences(of: "@PAD@", with: String(repeating: "a", count: pad)).utf8)
        } else {
            input = try bytes(hex: string(vector, "hex"))
        }
        let result = AgentCodec.decode(input)
        #expect(expectation(for: result) == vector["expect"], "\(vector["name"]?.stringValue ?? "?")")
        // What decodes re-encodes to something that decodes the same.
        if case .success(let message) = result {
            #expect(try AgentCodec.decode(AgentCodec.encode(message)).get() == message)
        }
    }
}

@Test func negotiationVectors() throws {
    for vector in try cases("vectors/negotiation.json") {
        guard case .array(let host)? = vector["host"], case .array(let agent)? = vector["agent"], host.count == 2, agent.count == 2
        else { throw VectorError.malformed("negotiation") }
        let (hostMin, hostMax) = (UInt32(try int(host[0])), UInt32(try int(host[1])))
        let (agentMin, agentMax) = (UInt32(try int(agent[0])), UInt32(try int(agent[1])))
        let expected = vector["expect"]?.intValue.map { UInt32($0) }
        // A host range is never empty in practice; the vectors include one to pin the Rust side's answer.
        let got = hostMin <= hostMax ? AgentLimits.negotiate(host: hostMin...hostMax, agentMin: agentMin, agentMax: agentMax) : nil
        #expect(got == expected, "\(vector)")
    }
}

@Test func limitsVersionsAndErrorCodesMatchTheSchema() throws {
    let schema = try proto("schema/protocol.json")
    let limits = try #require(schema["limits"])
    #expect(limits["maxJsonFrame"]?.intValue == Int64(AgentLimits.maxJSONFrame))
    #expect(limits["maxChunk"]?.intValue == Int64(AgentLimits.maxChunk))
    #expect(limits["maxOpenStreams"]?.intValue == Int64(AgentLimits.maxOpenStreams))
    #expect(limits["maxJsonDepth"]?.intValue == Int64(AgentLimits.maxJSONDepth))
    #expect(limits["maxString"]?.intValue == Int64(AgentLimits.maxString))
    #expect(limits["maxClipboardBytes"]?.intValue == Int64(AgentLimits.maxClipboardBytes))
    #expect(limits["maxClipboardChangedPerSecond"]?.intValue == Int64(AgentLimits.maxClipboardChangedPerSecond))
    #expect(limits["freezeDefaultTimeoutMs"]?.intValue == Int64(AgentLimits.freezeDefaultTimeoutMs))
    #expect(limits["freezeMaxTimeoutMs"]?.intValue == Int64(AgentLimits.freezeMaxTimeoutMs))
    #expect(schema["proto"]?.intValue == Int64(AgentLimits.proto))
    #expect(schema["minProto"]?.intValue == Int64(AgentLimits.minProto))

    let codes = try #require(schema["errorCodes"]?.objectValue)
    for code in AgentErrorCode.allCases {
        #expect(codes["\(code)"]?.intValue == Int64(code.rawValue), "\(code)")
    }
    for code in [ControlErrorCode.parseError, .invalidRequest, .methodNotFound, .invalidParams, .internalError] {
        #expect(codes["\(code)"]?.intValue == Int64(code.rawValue), "\(code)")
    }
    #expect(codes.count == AgentErrorCode.allCases.count + 5)
}

@Test func methodNamesMatchTheSchema() throws {
    let methods = try #require(try proto("schema/protocol.json")["methods"]?.objectValue)
    let swift: [String] = [
        AgentMethod.hello, AgentMethod.agentInfo, AgentMethod.agentPing, AgentMethod.agentHeartbeat, AgentMethod.transportAck,
        AgentMethod.execStart,
        AgentMethod.execSignal,
        AgentMethod.execExited, AgentMethod.filePush, AgentMethod.filePull, AgentMethod.fileStat, AgentMethod.fileMkdirTemp,
        AgentMethod.sessionReveal, AgentMethod.clipboardGet, AgentMethod.clipboardSet, AgentMethod.clipboardChanged,
        AgentMethod.displaySet, AgentMethod.timeSet, AgentMethod.powerShutdown, AgentMethod.netAddrs,
        AgentMethod.portsListening, AgentMethod.fsFreeze, AgentMethod.fsThaw, AgentMethod.screenElements,
        AgentMethod.sessionState, AgentMethod.dragProbe,
    ]
    #expect(Set(swift) == Set(methods.keys))
    let fromGuest = methods.filter { $0.value["direction"] == "guestToHost" }.map(\.key)
    #expect(Set(fromGuest) == AgentMethod.fromGuest)
}
