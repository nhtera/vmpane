import Foundation
import Testing
import VMPaneCore

@testable import VMPaneControl
@testable import VMPaneHost

/// A classifier that sees every peer as an unknown process (an agent's).
private let strangers = PeerClassifier(
    selfPID: -1, selfTeamID: nil, selfIsAdHoc: true, identify: { _ in nil }, satisfies: { _, _ in false })

/// A running VM whose agents may use input (`control`), its typed text not recorded, without undo snapshots.
private func runningAtControl() async throws -> Harness {
    let helper = try await Harness.make()
    _ = try await helper.client.call(
        "vm.settings.apply", params: ["patch": ["mcp": ["policy": "control", "auditTypedText": false, "autoSnapshot": false]]])
    #expect(try await helper.client.call("vm.start", params: ["headless": true])["state"] == "running")
    await helper.controller.setClassifier(strangers)
    return helper
}

private func auditText(_ helper: Harness) -> String {
    (try? String(contentsOf: helper.bundle.url.appendingPathComponent("logs/mcp-audit.jsonl"), encoding: .utf8)) ?? ""
}

private func oks(_ reply: JSONValue) -> [JSONValue?] {
    guard case .array(let results)? = reply["results"] else { return [] }
    return results.map { $0["ok"] }
}

/// A 64×48 frame (640×480 guest pixels), black but for `value` in `box`.
private func frame(_ value: UInt8, box: ScreenChange.Box? = nil) -> GrayFrame {
    var pixels = [UInt8](repeating: 0, count: 64 * 48)
    if let box {
        for y in box.y..<(box.y + box.height) { for x in box.x..<(box.x + box.width) { pixels[y * 64 + x] = value } }
    }
    return GrayFrame(width: 64, height: 48, pixels: pixels, scale: 10)
}

@Test func aBatchRunsEachActionAsTheRequestItStandsFor() async throws {
    let helper = try await runningAtControl()
    let reply = try await helper.client.call(
        "vm.input.batch",
        params: [
            "actions": [
                ["type": "click", "x": 100, "y": 50, "count": 2], ["type": "text", "text": "marker-7f3a", "submit": true],
                ["type": "key", "usages": [0xE0, 0x06]], ["type": "wait", "ms": 10], ["type": "scroll", "dy": -3],
            ],
            "settleMs": 0,
        ])
    #expect(oks(reply) == [true, true, true, true, true])
    let inputs = helper.backend.recordedCalls.filter { $0.hasPrefix("input.") }
    #expect(inputs.first == "input.pointer(x: 100.0, y: 50.0, buttons: 0)")
    #expect(inputs.filter { $0.contains("buttons: 1") }.count == 2, "a double click")
    #expect(inputs.contains("input.text(\"marker-7f3a\")"))
    #expect(
        Array(inputs.suffix(7)) == [
            "input.key(usage: 40, down: true)", "input.key(usage: 40, down: false)", "input.key(usage: 224, down: true)",
            "input.key(usage: 6, down: true)", "input.key(usage: 6, down: false)", "input.key(usage: 224, down: false)",
            "input.scroll(dx: 0.0, dy: -3.0)",
        ], "submit is Return; combinations are released in reverse")
    // One line per action (the wait has none) and one for the batch; the typed text is a hash on every line.
    let lines = auditText(helper).split(separator: "\n").compactMap { try? JSONDecoder().decode(AuditEntry.self, from: Data($0.utf8)) }
    #expect(lines.map(\.method) == ["vm.input.pointer", "vm.input.text", "vm.input.key", "vm.input.scroll", "vm.input.batch"])
    #expect(lines.last?.args?["actions"] == ["click", "text", "key", "wait", "scroll"])
    #expect(!auditText(helper).contains("marker-7f3a"))
    #expect(reply["verified"]?["status"] == "unknown" && reply["verified"]?["reason"] == "no_display")
    await helper.tearDown()
}

@Test func aBadBatchRunsNothing() async throws {
    let helper = try await runningAtControl()
    for actions: JSONValue in [
        [], .array(Array(repeating: ["type": "move", "x": 1, "y": 1], count: 51)), [["type": "move", "x": 1], ["type": "fly"]],
        [["type": "wait", "ms": 20000], ["type": "wait", "ms": 20000]],
    ] {
        await #expect(throws: RPCError.self) { try await helper.client.call("vm.input.batch", params: ["actions": actions]) }
    }
    #expect(!helper.backend.recordedCalls.contains { $0.hasPrefix("input.") })
    await helper.tearDown()
}

@Test func aFailedActionStopsTheRestUnlessAskedNotTo() async throws {
    let helper = try await runningAtControl()
    helper.backend.failNextInput = true
    let stopped = try await helper.client.call(
        "vm.input.batch", params: ["actions": [["type": "move", "x": 1, "y": 1], ["type": "move", "x": 2, "y": 2]], "settleMs": 0])
    #expect(oks(stopped) == [false])
    helper.backend.failNextInput = true
    let kept = try await helper.client.call(
        "vm.input.batch",
        params: ["actions": [["type": "move", "x": 1, "y": 1], ["type": "move", "x": 2, "y": 2]], "settleMs": 0, "stopOnError": false])
    #expect(oks(kept) == [false, true])
    await helper.tearDown()
}

@Test func theReplySaysWhetherTheScreenChanged() async throws {
    let helper = try await runningAtControl()
    let click: JSONValue = ["actions": [["type": "click", "x": 10, "y": 10]], "settleMs": 2000]
    // A dialog appears and stays: changed, around it, done well before settleMs.
    helper.backend.frames = [frame(0), frame(200, box: .init(x: 16, y: 16, width: 32, height: 16))]
    let opened = try await helper.client.call("vm.input.batch", params: click)
    let verified = try #require(opened["verified"])
    #expect(verified["status"] == "changed" && verified["settled"] == true)
    #expect(verified["bbox"] == ["x": 160, "y": 160, "width": 320, "height": 160], "guest pixels")
    #expect((verified["waitedMs"]?.intValue ?? 9999) < 1000)
    #expect(opened["screen"] == ["width": 640, "height": 480])
    // Nothing happens: unchanged, after settleMs.
    helper.backend.frames = [frame(0)]
    let still = try await helper.client.call("vm.input.batch", params: ["actions": [["type": "move", "x": 1, "y": 1]], "settleMs": 300])
    #expect(still["verified"]?["status"] == "unchanged" && still["verified"]?["reason"] == "no_pixel_change")
    #expect((still["verified"]?["waitedMs"]?.intValue ?? 0) >= 300)
    // A flash that is gone again by the end: unchanged.
    helper.backend.frames = [frame(0), frame(200, box: .init(x: 0, y: 0, width: 64, height: 48)), frame(0)]
    let flash = try await helper.client.call("vm.input.batch", params: ["actions": [["type": "move", "x": 1, "y": 1]], "settleMs": 300])
    #expect(flash["verified"]?["status"] == "unchanged")
    await helper.tearDown()
}

@Test func theKillSwitchStopsLongTypingAtOnce() async throws {
    let helper = try await runningAtControl()
    helper.backend.typingDelay = .milliseconds(8)  // VZ's pace: 3,000 characters take 24 s
    let typing = Task {
        try await helper.client.call(
            "vm.input.batch",
            params: [
                "actions": [["type": "text", "text": .string(String(repeating: "a", count: 3000))], ["type": "key", "usages": [40]]]
            ],
            timeout: .seconds(60))
    }
    try await Task.sleep(for: .milliseconds(500))
    let other = try UDSClient.connect(to: await helper.controller.prepared.runFiles.socketURL)
    defer { other.close() }
    _ = try await other.call("mcp.disableAll")
    let engaged = ContinuousClock.now
    await #expect(throws: (any Error).self) { try await typing.value }
    try await Task.sleep(for: .milliseconds(600))  // input still arriving after the answer would show here
    let calls = helper.backend.recordedCalls
    let lastInput = try #require(helper.backend.inputTimes.last)
    #expect(lastInput - engaged < .milliseconds(300), "no input 300 ms after the switch")
    #expect(!calls.contains("input.key(usage: 40, down: true)"), "the rest of the batch did not run")
    let typed = calls.filter { $0.hasPrefix("input.text") }.joined().filter { $0 == "a" }.count
    #expect(typed > 0 && typed < 3000)
    await helper.tearDown()
}

@Test func textThatCannotBeTypedFailsBeforeAnyOfIt() async throws {
    let helper = try await runningAtControl()
    let reply = try await helper.client.call("vm.input.batch", params: ["actions": [["type": "text", "text": "café"]], "settleMs": 0])
    #expect(oks(reply) == [false])
    #expect(!helper.backend.recordedCalls.contains { $0.hasPrefix("input.text") }, "not even \"caf\"")
    await helper.tearDown()
}

@Test func aClientThatLeavesStopsItsBatch() async throws {
    let helper = try await runningAtControl()
    helper.backend.typingDelay = .milliseconds(8)
    let agent = try UDSClient.connect(to: await helper.controller.prepared.runFiles.socketURL)
    let typing = Task {
        try await agent.call(
            "vm.input.batch", params: ["actions": [["type": "text", "text": .string(String(repeating: "a", count: 3000))]]],
            timeout: .seconds(60))
    }
    try await Task.sleep(for: .milliseconds(300))
    agent.close()
    let left = ContinuousClock.now
    _ = try? await typing.value
    try await Task.sleep(for: .milliseconds(600))
    let lastInput = try #require(helper.backend.inputTimes.last)
    #expect(lastInput - left < .milliseconds(300), "typing ends with the client")
    await helper.tearDown()
}

/// A client that half-closes after sending (`echo … | nc -U`) has its typing cut short, and is told why: not the kill
/// switch.
@Test func typingFromAHalfClosedClientSaysWhyItStopped() async throws {
    let helper = try await runningAtControl()
    helper.backend.typingDelay = .milliseconds(8)
    let path = await helper.controller.prepared.runFiles.socketURL.path
    let line = #"{"jsonrpc":"2.0","id":1,"method":"vm.input.text","params":{"text":"\#(String(repeating: "a", count: 300))"}}"#
    let answer = try halfClosedCall(path, line)
    #expect(answer.contains(HelperController.goneReason) && !answer.contains("kill switch"), "\(answer)")
    await helper.tearDown()
}

@Test func batchesOnOneVMRunOneAtATime() async throws {
    let helper = try await runningAtControl()
    let socket = await helper.controller.prepared.runFiles.socketURL
    let first = try UDSClient.connect(to: socket), second = try UDSClient.connect(to: socket)
    defer {
        first.close()
        second.close()
    }
    let held: JSONValue = ["actions": [["type": "key", "usages": [0xE1]], ["type": "wait", "ms": 200], ["type": "text", "text": "AB"]]]
    async let one = first.call("vm.input.batch", params: held)
    try await Task.sleep(for: .milliseconds(50))
    async let two = second.call("vm.input.batch", params: ["actions": [["type": "text", "text": "cd"]], "settleMs": 0])
    _ = try await (one, two)
    let typed = helper.backend.recordedCalls.filter { $0.hasPrefix("input.text") }
    #expect(typed == ["input.text(\"AB\")", "input.text(\"cd\")"], "the second waited for the first")
    await helper.tearDown()
}

@Test func aBatchTakesTheSessionsOneUndoSnapshot() async throws {
    let helper = try await Harness.make()
    _ = try await helper.client.call("vm.settings.apply", params: ["patch": ["mcp": ["policy": "control"]]])
    #expect(try await helper.client.call("vm.start", params: ["headless": true])["state"] == "running")
    await helper.controller.setClassifier(strangers)
    let agent = try UDSClient.connect(to: await helper.controller.prepared.runFiles.socketURL)
    defer { agent.close() }
    _ = try await agent.call(
        "helper.hello",
        params: ["proto": 1, "minProto": 1, "client": ["name": "claude-code", "version": "1", "kind": "mcp"], "sessionId": "s1"])
    let moves: JSONValue = .array((0..<3).map { ["type": "move", "x": .int(Int64($0)), "y": 1] })
    _ = try await agent.call("vm.input.batch", params: ["actions": moves, "settleMs": 0], timeout: .seconds(30))
    guard case .array(let all) = try await agent.call("vm.snapshot.list") else { throw RPCError(.internalError, "no list") }
    #expect(all.filter { $0["origin"] == "agentSession" }.count == 1)
    await helper.tearDown()
}
