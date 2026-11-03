import Foundation
import Testing
import VMPaneCore

@testable import VMPaneControl
@testable import VMPaneHost

// After the live undo snapshot, an agent's first input waits until the guest takes input again, and at least
// `afterLiveSnapshot` (#11).

/// A classifier that sees every peer as an unknown process (an agent's).
private let strangers = PeerClassifier(
    selfPID: -1, selfTeamID: nil, selfIsAdHoc: true, identify: { _ in nil }, satisfies: { _, _ in false })

private let probeDown = "input.\(InputEvent.key(usage: HelperController.probeUsage, down: true))"
private let agentKey = "input.\(InputEvent.key(usage: 0xE3, down: true))"

/// The probe keys (down) the backend got so far.
private func probes(_ helper: Harness) -> Int { helper.backend.recordedCalls.filter { $0 == probeDown }.count }

/// A guest whose agent answers `input.idle` with `answer(probes so far, calls so far)`: idle milliseconds, or nil for
/// an error (no signed-in session).
private func connectGuest(_ helper: Harness, answer: @escaping @Sendable (Int, Int) -> Int?) async throws -> Task<Void, Never> {
    let (agent, hostFD) = try FakeAgent.pair()
    helper.backend.connectAgent(hostFD)
    try agent.hello(caps: ["exec", "input.idle"])
    _ = await agent.nextMessage()  // the hello's answer
    let answering = Task.detached {
        var calls = 0
        while !Task.isCancelled, let message = await agent.nextMessage(within: 5) {
            guard case .request(let request) = message, let id = request.id else { continue }
            guard request.method == AgentMethod.inputIdle else {
                try? agent.send(.response(RPCResponse(id: id, result: [:])))
                continue
            }
            calls += 1
            if let idle = answer(probes(helper), calls) {
                try? agent.send(.response(RPCResponse(id: id, result: ["idleMs": .int(Int64(idle))])))
            } else {
                let noSession = RPCError(code: AgentErrorCode.noSession.rawValue, message: "no session")
                try? agent.send(.response(RPCResponse(id: id, error: noSession)))
            }
        }
    }
    try await Task.sleep(for: .milliseconds(200))
    return answering
}

/// A running Windows VM at `control` with a guest answering as `answer`; an agent session's first key, the calls the
/// backend got, and how long after the request the agent's key went.
private func firstAgentKey(answer: @escaping @Sendable (Int, Int) -> Int?) async throws -> ([String], Duration) {
    let helper = try await Harness.make(os: .windows)
    _ = try await helper.client.call("vm.settings.apply", params: ["patch": ["mcp": ["policy": "control"]]])
    #expect(try await helper.client.call("vm.start", params: ["headless": true])["state"] == "running")
    let answering = try await connectGuest(helper, answer: answer)
    await helper.controller.setClassifier(strangers)
    let client = try UDSClient.connect(to: await helper.controller.prepared.runFiles.socketURL)
    _ = try await client.call(
        "helper.hello",
        params: ["proto": 1, "minProto": 1, "client": ["name": "claude-code", "version": "1", "kind": "mcp"], "sessionId": "s1"])
    let started = ContinuousClock.now
    _ = try await client.call("vm.input.batch", params: ["actions": [["type": "key", "usages": [0xE3]]], "settleMs": 0])
    let calls = helper.backend.recordedCalls.filter { $0.hasPrefix("input.") }
    let keyIndex = calls.firstIndex(of: agentKey) ?? 0
    let keyTime = helper.backend.inputTimes[keyIndex]
    answering.cancel()
    client.close()
    await helper.tearDown()
    return (calls, keyTime - started)
}

@Test func aLostProbeIsSentAgainBeforeTheAgentsFirstKey() async throws {
    // The guest loses the first probe and takes the second.
    let (calls, _) = try await firstAgentKey { probes, _ in probes >= 2 ? 0 : 60000 }
    let key = try #require(calls.firstIndex(of: agentKey))
    #expect(calls[..<key].filter { $0 == probeDown }.count == 2, "\(calls)")
}

@Test func aGuestThatTakesTheProbeAtOnceStillGetsTheWaitAfterTheSnapshot() async throws {
    let (calls, waited) = try await firstAgentKey { probes, _ in probes >= 1 ? 0 : 60000 }
    #expect(calls.contains(probeDown))
    #expect(waited >= HelperController.afterLiveSnapshot, "the snapshot's own pause, then at least the fixed wait")
}

@Test func withoutASessionToAskTheWaitIsTheFixedOneAndNoProbeIsSent() async throws {
    let (calls, waited) = try await firstAgentKey { _, _ in nil }
    #expect(!calls.contains(probeDown), "\(calls)")
    #expect(waited >= HelperController.afterLiveSnapshot)
}

@Test func anAnswerThatFailsMidwayStillLeavesTheFixedWait() async throws {
    // The availability check answers; the first poll after the probe fails.
    let (calls, waited) = try await firstAgentKey { _, call in call == 1 ? 60000 : nil }
    #expect(calls.contains(probeDown))
    #expect(waited >= HelperController.afterLiveSnapshot)
}
