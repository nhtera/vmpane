import Foundation
import Synchronization
import Testing
import VMPaneCore

@testable import VMPaneMCP

/// The server with a scripted tool set, and what it sent.
private final class Wire: Sendable {
    let sent = Mutex<[JSONValue]>([])
    var messages: [JSONValue] { sent.withLock { $0 } }

    func server(_ tools: [Tool] = Wire.tools) -> MCPServer {
        MCPServer(registry: ToolRegistry(tools), version: "9.9") { [self] data in
            if let value = try? JSONDecoder().decode(JSONValue.self, from: data) { sent.withLock { $0.append(value) } }
        }
    }

    static let tools = [
        Tool("echo", "Echoes.", schema: Schema.object(["text": Schema.string("What.")], required: ["text"])) { args, _ in
            ToolResult(text: args["text"]?.stringValue ?? "", structured: ["echo": args["text"] ?? .null])
        },
        Tool("slow", "Takes a while.", schema: Schema.object([:])) { _, context in
            await context.progress(1, 2, "half")
            try await Task.sleep(for: .seconds(5))
            return ToolResult(text: "done")
        },
        Tool("refused", "Fails like a policy refusal.", schema: Schema.object([:])) { _, _ in throw ToolFailure("needs exec") },
    ]

    func answer(_ id: JSONValue, within seconds: Double = 2) async -> JSONValue? {
        for _ in 0..<Int(seconds * 50) {
            if let found = messages.first(where: { $0["id"] == id }) { return found }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return nil
    }
}

private func line(_ value: JSONValue) -> Data { MCPServer.encode(value) }

@Test func legacyClientsShakeHandsFirst() async throws {
    let wire = Wire()
    let server = wire.server()
    await server.receive(line(["jsonrpc": "2.0", "id": 1, "method": "tools/list"]))
    #expect(await wire.answer(1)?["error"]?["code"] == -32600, "no session yet")
    await server.receive(
        line([
            "jsonrpc": "2.0", "id": 2, "method": "initialize",
            "params": ["protocolVersion": "2025-06-18", "clientInfo": ["name": "claude-code", "version": "2.0"], "capabilities": [:]],
        ]))
    let hello = await wire.answer(2)
    #expect(hello?["result"]?["protocolVersion"] == "2025-06-18" && hello?["result"]?["serverInfo"]?["name"] == "vmpane")
    #expect(await server.clientName == "claude-code 2.0")
    await server.receive(line(["jsonrpc": "2.0", "method": "notifications/initialized"]))
    await server.receive(line(["jsonrpc": "2.0", "id": 3, "method": "tools/list"]))
    guard case .array(let tools)? = await wire.answer(3)?["result"]?["tools"] else {
        Issue.record("no tools")
        return
    }
    #expect(tools.compactMap { $0["name"]?.stringValue } == ["echo", "slow", "refused"], "in a fixed order")
    await server.receive(line(["jsonrpc": "2.0", "id": 4, "method": "ping"]))
    #expect(await wire.answer(4)?["result"] == [:])
}

@Test func modernClientsSayTheirVersionInEachRequest() async throws {
    let wire = Wire()
    let server = wire.server()
    let meta: JSONValue = [
        "io.modelcontextprotocol/protocolVersion": "2026-07-28", "io.modelcontextprotocol/clientInfo": ["name": "codex"],
    ]
    await server.receive(
        line(["jsonrpc": "2.0", "id": "a", "method": "tools/call", "params": ["name": "echo", "arguments": ["text": "hi"], "_meta": meta]]))
    let echoed = await wire.answer("a")
    #expect(echoed?["result"]?["resultType"] == "complete" && echoed?["result"]?["structuredContent"]?["echo"] == "hi")
    #expect(await server.clientName == "codex")
    let unknown: JSONValue = ["io.modelcontextprotocol/protocolVersion": "2030-01-01"]
    await server.receive(line(["jsonrpc": "2.0", "id": 7, "method": "tools/list", "params": ["_meta": unknown]]))
    #expect(await wire.answer(7)?["error"]?["code"] == -32022)
    await server.receive(line(["jsonrpc": "2.0", "id": 8, "method": "server/discover", "params": ["_meta": meta]]))
    guard case .array(let versions)? = await wire.answer(8)?["result"]?["supportedVersions"] else {
        Issue.record("no versions")
        return
    }
    #expect(versions.first == "2026-07-28")
}

@Test func toolFailuresAreResultsAndCancelledCallsGetNoAnswer() async throws {
    let wire = Wire()
    let server = wire.server()
    await server.receive(line(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "2025-11-25"]]))
    await server.receive(line(["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": ["name": "refused"]]))
    let refused = await wire.answer(2)
    #expect(refused?["result"]?["isError"] == true && refused?["error"] == nil)
    await server.receive(line(["jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": ["name": "nope"]]))
    #expect(await wire.answer(3)?["error"]?["code"] == -32602)
    await server.receive(
        line(["jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": ["name": "slow", "_meta": ["progressToken": "p1"]]]))
    try await Task.sleep(for: .milliseconds(200))
    #expect(wire.messages.contains { $0["method"] == "notifications/progress" && $0["params"]?["progressToken"] == "p1" })
    await server.receive(line(["jsonrpc": "2.0", "method": "notifications/cancelled", "params": ["requestId": 4]]))
    #expect(await wire.answer(4, within: 1) == nil, "a cancelled request is not answered")
    await server.receive(Data("not json".utf8))
    #expect(wire.messages.last?["error"]?["code"] == -32700)
}

/// When the client closes its input, calls still running get their answers out first. The call answers when the
/// test lets it, not after a fixed time: a loaded machine cannot make the drain end first.
@Test func answersInFlightGoOutBeforeTheServerEnds() async throws {
    let wire = Wire()
    let (released, release) = AsyncStream<Void>.makeStream()
    let gated = Tool("gated", "Answers when the test lets it.", schema: Schema.object([:])) { _, _ in
        for await _ in released { break }
        return ToolResult(text: "done")
    }
    let server = wire.server([gated])
    let meta: JSONValue = ["io.modelcontextprotocol/protocolVersion": "2026-07-28"]
    await server.receive(
        line(["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": "gated", "arguments": [:], "_meta": meta]]))
    let drained = Mutex(false)
    let draining = Task {
        await server.drain(within: .seconds(60))
        drained.withLock { $0 = true }
    }
    try await Task.sleep(for: .milliseconds(200))
    #expect(!drained.withLock { $0 }, "the drain waits while the call runs")
    release.yield()
    await draining.value
    #expect(wire.messages.contains { $0["id"] == 1 && $0["result"] != nil })
}
