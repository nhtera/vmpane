import Foundation
import Testing
import VMPaneCore

@testable import VMPaneControl

/// Seeded, reproducible generator (SplitMix64).
private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        return mixed ^ (mixed >> 31)
    }
}

/// Mutation count: 20k per run; the nightly fuzz smoke sets VMPANE_FUZZ_ITERATIONS=1000000.
private let iterations = Int(ProcessInfo.processInfo.environment["VMPANE_FUZZ_ITERATIONS"] ?? "") ?? 20_000

private func seedFrames() throws -> [Data] {
    let messages = [
        #"{"jsonrpc":"2.0","id":1,"method":"hello","params":{"proto":1,"minProto":1,"agentVersion":"1.0.0","os":"linux","arch":"arm64"}}"#,
        #"{"jsonrpc":"2.0","method":"exec.exited","params":{"execId":2,"code":0}}"#,
        #"{"jsonrpc":"2.0","id":"x","error":{"code":-32042,"message":"no such file","data":[1,{"a":null}]}}"#,
    ]
    return try messages.map { try AgentFrame.message(Data($0.utf8)).encoded() } + [
        try AgentFrame.chunk(stream: 2, data: Data("some stream bytes".utf8)).encoded(),
        try AgentFrame.end(stream: 2, status: .ok).encoded(),
    ]
}

private func mutate(_ input: Data, using rng: inout SplitMix64) -> Data {
    var bytes = [UInt8](input)
    for _ in 0..<Int.random(in: 1...4, using: &rng) {
        switch Int.random(in: 0..<5, using: &rng) {
        case 0 where !bytes.isEmpty: bytes[Int.random(in: 0..<bytes.count, using: &rng)] ^= UInt8(1 << Int.random(in: 0..<8, using: &rng))
        case 1 where !bytes.isEmpty: bytes[Int.random(in: 0..<bytes.count, using: &rng)] = UInt8.random(in: 0...255, using: &rng)
        case 2: bytes.insert(UInt8.random(in: 0...255, using: &rng), at: Int.random(in: 0...bytes.count, using: &rng))
        case 3 where !bytes.isEmpty: bytes.remove(at: Int.random(in: 0..<bytes.count, using: &rng))
        default:
            // Interesting bytes the format cares about: lengths, types, brackets, quotes, backslashes.
            let special: [UInt8] = [0x00, 0xFF, 0x01, 0x02, 0x7B, 0x5B, 0x22, 0x5C, 0x7D, 0x5D]
            bytes.insert(special[Int.random(in: 0..<special.count, using: &rng)], at: Int.random(in: 0...bytes.count, using: &rng))
        }
    }
    return Data(bytes)
}

/// Random mutations of valid frame streams, fed in random pieces: the decoder and the message codec either
/// return values or errors, never crash, and never hold more than one maximal frame plus the latest input.
@Test func mutatedFramesNeverCrashOrOverBuffer() throws {
    let seeds = try seedFrames()
    var rng = SplitMix64(state: 0x5EED)
    let bound = 4 + 1 + AgentLimits.maxJSONFrame
    for _ in 0..<iterations {
        var stream = Data()
        for _ in 0..<Int.random(in: 1...3, using: &rng) { stream.append(seeds[Int.random(in: 0..<seeds.count, using: &rng)]) }
        let input = mutate(stream, using: &rng)
        var decoder = AgentFrameDecoder()
        var offset = 0
        decoding: while offset < input.count {
            let piece = Int.random(in: 1...16, using: &rng)
            decoder.append(input[offset..<min(offset + piece, input.count)])
            offset += piece
            do {
                while let frame = try decoder.next() {
                    if case .message(let json) = frame { _ = AgentCodec.decode(json) }
                }
            } catch {
                break decoding
            }
            #expect(decoder.bufferedCount <= bound)
        }
    }
}

/// Mutated message payloads straight into the message codec.
@Test func mutatedMessagesNeverCrash() throws {
    var rng = SplitMix64(state: 0xC0DEC)
    let json = Data(#"{"jsonrpc":"2.0","id":1,"method":"m","params":{"a":[1,2,{"b":"c\"d"}],"e":null}}"#.utf8)
    for _ in 0..<iterations {
        let mutated = mutate(json, using: &rng)
        if case .success(let message) = AgentCodec.decode(mutated) {
            // Anything accepted must re-encode within the limits.
            _ = try AgentCodec.encode(message)
        }
    }
}

@Test func deepNestingIsRejectedBeforeParsing() {
    // Far beyond any parser's recursion limit: must be refused by the byte scan, not crash the decoder.
    let deep = Data(String(repeating: "[", count: 1_000_000).utf8)
    #expect(AgentCodec.decode(deep) == .failure(.depth))
}
