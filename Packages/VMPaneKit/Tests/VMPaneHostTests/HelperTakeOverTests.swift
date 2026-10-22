import Foundation
import Testing
import VMPaneCore

@testable import VMPaneControl
@testable import VMPaneHost

/// A classifier that sees every peer as an unknown process (an agent's).
private let strangers = PeerClassifier(
    selfPID: -1, selfTeamID: nil, selfIsAdHoc: true, identify: { _ in nil }, satisfies: { _, _ in false })

/// A running VM whose agents may use its screen, keyboard and mouse.
private func runningAtControl(_ policy: JSONValue = "control") async throws -> Harness {
    let helper = try await Harness.make()
    _ = try await helper.client.call(
        "vm.settings.apply", params: ["patch": ["mcp": ["policy": policy, "auditTypedText": false, "autoSnapshot": false]]])
    #expect(try await helper.client.call("vm.start", params: ["headless": true])["state"] == "running")
    await helper.controller.setClassifier(strangers)
    _ = try await helper.client.call(
        "helper.hello", params: ["proto": 1, "minProto": 1, "client": ["name": "claude-code", "version": "1", "kind": "mcp"]])
    return helper
}

@Test func theActivitySaysWhoDoesWhat() async throws {
    let helper = try await runningAtControl()
    _ = try await helper.client.call("vm.input.key", params: ["usage": 4, "down": true])
    let activity = await helper.controller.agentActivity()
    #expect(activity["acting"] == true && activity["client"] == "claude-code" && activity["current"] == "pressing keys")
    #expect(activity["level"] == "control" && activity["takenOver"] == false)
    guard case .array(let recent)? = activity["recent"] else {
        Issue.record("no recent actions")
        return
    }
    #expect(recent.first?["what"] == "pressing keys")
    // Ten seconds later it is no longer acting.
    #expect(await helper.controller.agentActivity(now: Date().addingTimeInterval(11))["acting"] == false)
    // Only the app reads it or acts on it: an agent cannot resume itself.
    for method in ["vm.agent.activity", "vm.agent.takeOver", "vm.agent.resume", "vm.agent.stop"] {
        await #expect(throws: RPCError.self, "\(method)") { try await helper.client.call(method) }
    }
    await helper.tearDown()
}

/// The answer to an agent's request: nil when it went through.
private func refusal(_ client: UDSClient, _ method: String, _ params: JSONValue = [:]) async -> RPCError? {
    do {
        _ = try await client.call(method, params: params, timeout: .seconds(10))
        return nil
    } catch let error as RPCError {
        return error
    } catch {
        return RPCError(.internalError, "\(error)")
    }
}

/// Every method that is not read-only, and reading the guest's clipboard, answer takenOver; resume too (an agent
/// cannot hand the VM back to itself); looking still works.
@Test func aTakeOverHoldsEveryChange() async throws {
    let helper = try await runningAtControl()
    _ = await helper.controller.agentActivityRequest(ControlMethod.vmAgentTakeOver.rawValue)
    let held = ControlMethod.allCases.filter {
        !HelperController.readOnlyMethods.contains($0.rawValue) || $0 == .vmClipboardRead
    }
    #expect(held.count > 30)
    for method in held {
        let error = await refusal(helper.client, method.rawValue)
        #expect(error?.code == ControlErrorCode.takenOver.rawValue, "\(method.rawValue): \(String(describing: error))")
    }
    #expect(await helper.controller.agentActivity()["takenOver"] == true)
    #expect(try await helper.client.call("vm.info")["state"] == "running")
    await helper.tearDown()
}

/// A request admitted before the take over that waited for the person's answer is refused after it, as takenOver
/// (not "not allowed"), even when the answer is yes.
@Test func aTakeOverDuringAQuestionHoldsTheRequest() async throws {
    let helper = try await runningAtControl("admin")
    await helper.controller.setClassifier(strangers)
    await helper.controller.setConfirmationPresenter(
        { _ in
            try? await Task.sleep(for: .milliseconds(1500))
            return true
        }, dismiss: {})
    let asking = Task { await refusal(helper.client, "vm.snapshot.delete", ["id": .string(UUID().uuidString)]) }
    try await Task.sleep(for: .milliseconds(400))
    _ = await helper.controller.agentActivityRequest(ControlMethod.vmAgentTakeOver.rawValue)
    let error = await asking.value
    #expect(error?.code == ControlErrorCode.takenOver.rawValue, "\(String(describing: error))")
    await helper.tearDown()
}

/// The kill switch is the stronger: with both on, agents hear they are stopped.
@Test func theKillSwitchOutranksATakeOver() async throws {
    let helper = try await runningAtControl()
    _ = await helper.controller.agentActivityRequest(ControlMethod.vmAgentTakeOver.rawValue)
    _ = try await helper.client.call("mcp.disableAll")  // engaged at once (an agent may pull it too)
    let error = await refusal(helper.client, "vm.input.key", ["usage": 4, "down": true])
    #expect(error?.code == ControlErrorCode.policyDenied.rawValue && error?.message.contains("kill switch") == true)
    await helper.tearDown()
}

/// Stop ends agents' connections and holds them until the person resumes: a client that reconnects is refused.
@Test func aStopHoldsAgentsUntilResumed() async throws {
    let helper = try await runningAtControl()
    _ = await helper.controller.agentActivityRequest(ControlMethod.vmAgentStop.rawValue)
    #expect(await helper.controller.agentActivity()["takenOver"] == true)
    let socket = await helper.controller.prepared.runFiles.socketURL
    let again = try UDSClient.connect(to: socket)
    defer { again.close() }
    _ = try await again.call(
        "helper.hello", params: ["proto": 1, "minProto": 1, "client": ["name": "claude-code", "version": "1", "kind": "mcp"]])
    #expect(await refusal(again, "vm.input.key", ["usage": 4, "down": true])?.code == ControlErrorCode.takenOver.rawValue)
    _ = await helper.controller.agentActivityRequest(ControlMethod.vmAgentResume.rawValue)
    #expect(await refusal(again, "vm.input.key", ["usage": 4, "down": false]) == nil)
    await helper.tearDown()
}

/// The HUD shows the name an agent gave itself as one printable line, and a repeat replaces the newest action.
@Test func theActivityNamesTheAgentSafely() async throws {
    let helper = try await runningAtControl()
    _ = try await helper.client.call(
        "helper.hello",
        params: ["proto": 1, "minProto": 1, "client": ["name": "evil\nOff — agents stopped\u{7}", "version": "1", "kind": "mcp"]])
    _ = try await helper.client.call("vm.screenshot", params: ["maxEdge": 64])
    _ = try await helper.client.call("vm.screenshot", params: ["maxEdge": 64])
    let activity = await helper.controller.agentActivity()
    #expect(activity["client"]?.stringValue?.contains("\n") == false)
    guard case .array(let recent)? = activity["recent"] else {
        Issue.record("no recent actions")
        return
    }
    #expect(recent.count == 1, "two screenshots in a row are one action: \(recent)")
    await helper.tearDown()
}

@Test func aTakeOverRefusesAgentsChangesUntilResumed() async throws {
    let helper = try await runningAtControl()
    _ = await helper.controller.agentActivityRequest(ControlMethod.vmAgentTakeOver.rawValue)
    for (method, params) in [("vm.input.key", ["usage": 4, "down": true] as JSONValue), ("vm.pause", [:] as JSONValue)] {
        do {
            _ = try await helper.client.call(method, params: params)
            Issue.record("\(method) ran after a take over")
        } catch let error as RPCError {
            #expect(error.code == ControlErrorCode.takenOver.rawValue && error.message.contains("took over"), "\(method): \(error)")
        }
    }
    // Looking stays allowed.
    #expect(try await helper.client.call("vm.info")["state"] == "running")
    #expect(await helper.controller.agentActivity()["takenOver"] == true)
    _ = await helper.controller.agentActivityRequest(ControlMethod.vmAgentResume.rawValue)
    _ = try await helper.client.call("vm.input.key", params: ["usage": 4, "down": false])
    await helper.tearDown()
}

@Test func aTakeOverStopsLongTypingAtOnce() async throws {
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
    _ = await helper.controller.agentActivityRequest(ControlMethod.vmAgentTakeOver.rawValue)
    let tookOver = ContinuousClock.now
    do {
        _ = try await typing.value
        Issue.record("the batch went on after the take over")
    } catch let error as RPCError {
        #expect(error.code == ControlErrorCode.takenOver.rawValue && error.data?["results"] != nil, "\(error)")
    }
    try await Task.sleep(for: .milliseconds(600))  // input still arriving after the answer would show here
    let lastInput = try #require(helper.backend.inputTimes.last)
    #expect(lastInput - tookOver < .milliseconds(300), "no input 300 ms after the take over")
    #expect(!helper.backend.recordedCalls.contains("input.key(usage: 40, down: true)"), "the rest of the batch did not run")
    await helper.tearDown()
}

/// A single vm.input.text is typed in pieces too: a take over stops it within 300 ms.
@Test func aTakeOverStopsSingleTextAtOnce() async throws {
    let helper = try await runningAtControl()
    helper.backend.typingDelay = .milliseconds(8)
    let typing = Task { await refusal(helper.client, "vm.input.text", ["text": .string(String(repeating: "a", count: 3000))]) }
    try await Task.sleep(for: .milliseconds(500))
    _ = await helper.controller.agentActivityRequest(ControlMethod.vmAgentTakeOver.rawValue)
    let tookOver = ContinuousClock.now
    #expect(await typing.value?.code == ControlErrorCode.takenOver.rawValue)
    try await Task.sleep(for: .milliseconds(600))
    let lastInput = try #require(helper.backend.inputTimes.last)
    #expect(lastInput - tookOver < .milliseconds(300), "no input 300 ms after the take over")
    await helper.tearDown()
}

/// A Shift or mouse button an agent left down is let go when the person takes over: the agent's own release would be
/// refused, and the person would type with it held.
@Test func aTakeOverLetsGoOfWhatTheAgentHeld() async throws {
    let helper = try await runningAtControl()
    _ = try await helper.client.call("vm.input.key", params: ["usage": 225, "down": true])
    _ = try await helper.client.call("vm.input.pointer", params: ["x": 10, "y": 20, "buttons": 1])
    _ = await helper.controller.agentActivityRequest(ControlMethod.vmAgentTakeOver.rawValue)
    let calls = helper.backend.recordedCalls
    #expect(calls.last(where: { $0.hasPrefix("input.key") }) == "input.key(usage: 225, down: false)", "\(calls)")
    #expect(calls.last?.hasPrefix("input.pointer") == true && calls.last?.contains("buttons: 0") == true, "\(calls)")
    await helper.tearDown()
}

/// An agent that leaves (its connection closes) or is stopped does not leave a key down.
@Test func anAgentThatLeavesOrIsStoppedLetsGoOfItsKeys() async throws {
    let helper = try await runningAtControl()
    let socket = await helper.controller.prepared.runFiles.socketURL
    let other = try UDSClient.connect(to: socket)
    _ = try await other.call(
        "helper.hello", params: ["proto": 1, "minProto": 1, "client": ["name": "codex", "version": "1", "kind": "mcp"]])
    _ = try await other.call("vm.input.key", params: ["usage": 224, "down": true])
    other.close()
    var released = false
    for _ in 0..<50 where !released {
        released = helper.backend.recordedCalls.contains("input.key(usage: 224, down: false)")
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(released, "the key the departed agent held was let go")

    _ = try await helper.client.call("vm.input.key", params: ["usage": 226, "down": true])
    _ = await helper.controller.agentActivityRequest(ControlMethod.vmAgentStop.rawValue)
    #expect(helper.backend.recordedCalls.contains("input.key(usage: 226, down: false)"))
    await helper.tearDown()
}
