import Foundation
import Testing
import VMPaneCore

@testable import VMPaneControl

private func decode(_ text: String) -> Result<RPCMessage, RPCCodec.DecodeFailure> {
    RPCCodec.decode(Data(text.utf8))
}

@Test func requestAndNotificationDecode() throws {
    let info = try decode(#"{"jsonrpc":"2.0","id":7,"method":"vm.info"}"#).get()
    #expect(info == .request(RPCRequest(id: .int(7), method: "vm.info")))
    let start = try decode(#"{"jsonrpc":"2.0","id":"a","method":"vm.start","params":{"headless":true}}"#).get()
    #expect(start == .request(RPCRequest(id: .string("a"), method: "vm.start", params: ["headless": true])))
    let notification = try decode(#"{"jsonrpc":"2.0","method":"vm.stateChanged","params":{"state":"running"}}"#).get()
    guard case .request(let request) = notification else { Issue.record("not a request"); return }
    #expect(request.isNotification)
}

@Test func responsesDecode() throws {
    let result = try decode(#"{"jsonrpc":"2.0","id":1,"result":{"ok":true}}"#).get()
    #expect(result == .response(RPCResponse(id: .int(1), result: ["ok": true])))
    #expect(
        try decode(#"{"jsonrpc":"2.0","id":1,"error":{"code":-32012,"message":"denied"}}"#).get()
            == .response(RPCResponse(id: .int(1), error: RPCError(.policyDenied, "denied"))))
}

@Test(arguments: [
    (#"{"jsonrpc":"2.0","id":1,"method":"x""#, ControlErrorCode.parseError),
    (#"[{"jsonrpc":"2.0","id":1,"method":"x"}]"#, .invalidRequest),
    (#""just a string""#, .invalidRequest),
    (#"{"jsonrpc":"2.0","id":1.5,"method":"x"}"#, .invalidRequest),
    (#"{"jsonrpc":"2.0","id":{},"method":"x"}"#, .invalidRequest),
    (#"{"jsonrpc":"1.0","id":1,"method":"x"}"#, .invalidRequest),
    (#"{"jsonrpc":"2.0","id":1,"method":3}"#, .invalidRequest),
    (#"{"jsonrpc":"2.0","id":1,"method":"x","params":"no"}"#, .invalidRequest),
    (#"{"jsonrpc":"2.0","id":1}"#, .invalidRequest),
])
func malformedMessagesMapToErrors(line: String, code: ControlErrorCode) {
    guard case .failure(let failure) = decode(line) else { Issue.record("accepted: \(line)"); return }
    #expect(failure.error.knownCode == code)
}

@Test func invalidRequestKeepsAReadableID() {
    guard case .failure(let failure) = decode(#"{"jsonrpc":"1.0","id":"keep","method":"x"}"#) else { Issue.record("accepted"); return }
    #expect(failure.id == .string("keep"))
}

@Test func encodingIsCompactSortedAndNewlineTerminated() throws {
    let request = try RPCCodec.encode(.request(RPCRequest(id: .int(1), method: "vm.info", params: ["b": 1, "a": "x/y"])))
    #expect(String(bytes: request, encoding: .utf8) == #"{"id":1,"jsonrpc":"2.0","method":"vm.info","params":{"a":"x/y","b":1}}"# + "\n")
    let error = try RPCCodec.encode(.response(RPCResponse(id: nil, error: RPCError(.parseError, "parse error"))))
    let expected = #"{"error":{"code":-32700,"message":"parse error"},"id":null,"jsonrpc":"2.0"}"# + "\n"
    #expect(String(bytes: error, encoding: .utf8) == expected)
}

@Test func encodeDecodeRoundTrip() throws {
    let messages: [RPCMessage] = [
        .request(RPCRequest(id: .string("x"), method: "vm.snapshot.create", params: ["name": "s", "kind": "disk"])),
        .request(RPCRequest(id: nil, method: "exec.output", params: ["execId": 1, "stream": "stdout", "dataB64": "aGk="])),
        .response(RPCResponse(id: .int(3), result: .null)),
        .response(RPCResponse(id: .int(4), error: RPCError(.busy, "busy", data: ["retryMs": 100]))),
    ]
    for message in messages {
        let line = try RPCCodec.encode(message).dropLast()
        #expect(try RPCCodec.decode(Data(line)).get() == message)
    }
}

@Test func framerSplitsLinesAcrossChunks() {
    var framer = LineFramer()
    #expect(framer.append(Data("{\"a\":1}\n{\"b\"".utf8)) == [.line(Data("{\"a\":1}".utf8))])
    #expect(framer.append(Data(":2}\r\n\n".utf8)) == [.line(Data("{\"b\":2}".utf8))])
}

@Test func framerCapsLineLength() {
    var framer = LineFramer(maxLineBytes: 8)
    #expect(framer.append(Data("12345678\n".utf8)) == [.line(Data("12345678".utf8))])
    #expect(framer.append(Data("123456789".utf8)) == [.overflow])
    var real = LineFramer()
    #expect(real.append(Data(repeating: 0x41, count: RPCCodec.maxLineBytes + 1)) == [.overflow])
}
