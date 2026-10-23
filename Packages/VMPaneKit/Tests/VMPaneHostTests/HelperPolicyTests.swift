import Darwin
import Foundation
import Testing
import VMPaneCore

@testable import VMPaneControl
@testable import VMPaneHost

/// A classifier that sees every peer as an unknown process (an agent's).
private let strangers = PeerClassifier(
    selfPID: -1, selfTeamID: nil, selfIsAdHoc: true, identify: { _ in nil }, satisfies: { _, _ in false })

private func entries(_ helper: Harness) throws -> [AuditEntry] {
    let url = helper.bundle.url.appendingPathComponent("logs/mcp-audit.jsonl")
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
    return try text.split(separator: "\n").map { try JSONDecoder().decode(AuditEntry.self, from: Data($0.utf8)) }
}

@Test func agentsAreHeldToTheVMsPolicy() async throws {
    let helper = try await Harness.make()
    await helper.controller.setClassifier(strangers)
    // Policy off: nothing, and the refusal is recorded.
    await #expect(throws: RPCError.self) { try await helper.client.call("vm.info") }
    let log = try entries(helper)
    #expect(log.last?.method == "vm.info" && log.last?.result == "denied" && log.last?.identity == "automated")
    await helper.tearDown()
}

@Test func aTaggedPolicyOpensItsLevelOnly() async throws {
    let helper = try await Harness.make()
    // Set as the app sets it (this connection is still the app's): tagged.
    _ = try await helper.client.call("vm.settings.apply", params: ["patch": ["mcp": ["policy": "observe"]]])
    await helper.controller.setClassifier(strangers)
    #expect(try await helper.client.call("vm.info")["state"] == "stopped")
    do {
        _ = try await helper.client.call("vm.start")
        Issue.record("vm.start needs control")
    } catch let error as RPCError {
        #expect(error.code == ControlErrorCode.policyDenied.rawValue)
    }
    let log = try entries(helper)
    #expect(log.map { $0.result } == ["ok", "denied"])
    #expect(log.map { $0.method } == ["vm.info", "vm.start"])
    #expect(log.allSatisfy { $0.policy == "observe" })
    await helper.tearDown()
}

@Test func aPolicyEditedByHandCountsAsOff() async throws {
    let helper = try await Harness.make(configure: { config in
        config.mcp.policy = .admin  // no tag
    })
    let info = try await helper.client.call("vm.info")  // as the app: it is told why the level does not count
    #expect(info["policy"] == "off" && info["policyTampered"] == true)
    await helper.controller.setClassifier(strangers)
    await #expect(throws: RPCError.self) { try await helper.client.call("vm.info") }
    #expect(try entries(helper).last?.policy == "off")
    await helper.tearDown()
}

@Test func theKillSwitchStopsAgentsButNotTheApp() async throws {
    let helper = try await Harness.make()
    _ = try await helper.client.call("vm.settings.apply", params: ["patch": ["mcp": ["policy": "admin"]]])
    await helper.controller.setClassifier(strangers)
    #expect(try await helper.client.call("vm.info")["state"] == "stopped", "an agent at admin")
    // Anyone may stop agents, the agent itself included.
    _ = try await helper.client.call("mcp.disableAll")
    #expect(KillSwitch.isEngaged(paths: helper.paths))
    // Its connection was closed; a new one is refused.
    let agent = try UDSClient.connect(to: await helper.controller.prepared.runFiles.socketURL)
    defer { agent.close() }
    await #expect(throws: RPCError.self) { try await agent.call("vm.info") }
    await #expect(throws: RPCError.self) { try await agent.call("mcp.enableAll") }  // only the app releases it
    #expect(try entries(helper).last?.reason?.contains("kill switch") == true)
    await helper.tearDown()
}

/// One request line through a client that half-closes after sending (`echo … | nc -U`); the answer line.
func halfClosedCall(_ path: String, _ line: String) throws -> String {
    let fd = try UnixSocket.make()
    defer { close(fd) }
    var timeout = timeval(tv_sec: 10, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    try UnixSocket.connect(fd, to: .absolute(path))
    try UnixSocket.writeAll(fd, Data((line + "\n").utf8))
    shutdown(fd, SHUT_WR)
    var answer = Data()
    var byte: UInt8 = 0
    while read(fd, &byte, 1) == 1, byte != 0x0A { answer.append(byte) }
    return String(bytes: answer, encoding: .utf8) ?? ""
}

@Test func anAgentThatHalfClosesAfterSendingIsAnswered() async throws {
    let helper = try await Harness.make()
    _ = try await helper.client.call("vm.settings.apply", params: ["patch": ["mcp": ["policy": "admin"]]])
    await helper.controller.setClassifier(strangers)
    let path = await helper.controller.prepared.runFiles.socketURL.path
    let answer = try halfClosedCall(path, #"{"jsonrpc":"2.0","id":1,"method":"vm.info"}"#)
    #expect(answer.contains(#""result""#), "\(answer)")
    await helper.tearDown()
}

@Test func anEngagedSwitchWrittenElsewhereIsNoticed() async throws {
    let helper = try await Harness.make()
    _ = try await helper.client.call("vm.settings.apply", params: ["patch": ["mcp": ["policy": "admin"]]])
    await helper.controller.setClassifier(strangers)
    try KillSwitch.engage(paths: helper.paths)  // vmpane mcp kill, with no app running
    try await Task.sleep(for: .milliseconds(1200))
    #expect(await helper.controller.killSwitchEngaged)
    await #expect(throws: RPCError.self) { try await helper.client.call("vm.info") }
    try KillSwitch.release(paths: helper.paths)
    try await Task.sleep(for: .milliseconds(1200))
    #expect(await !helper.controller.killSwitchEngaged)
    await helper.tearDown()
}

/// Removing the key file does not release the switch in a helper that holds the key.
@Test func removingTheKeyDoesNotReleaseTheSwitch() async throws {
    let helper = try await Harness.make()
    _ = try await helper.client.call("vm.settings.apply", params: ["patch": ["mcp": ["policy": "admin"]]])
    try KillSwitch.engage(paths: helper.paths)
    try await Task.sleep(for: .milliseconds(1200))
    #expect(await helper.controller.killSwitchEngaged)
    try FileManager.default.removeItem(at: PolicyKeyFile(paths: helper.paths).url)
    try await Task.sleep(for: .milliseconds(1200))
    #expect(await helper.controller.killSwitchEngaged)
    #expect(await helper.controller.effectivePolicy().level == .admin)
    await helper.tearDown()
}

private func hello(_ client: UDSClient, session: String) async throws {
    _ = try await client.call(
        "helper.hello",
        params: [
            "proto": 1, "minProto": 1, "client": ["name": "claude-code", "version": "1", "kind": "mcp"], "sessionId": .string(session),
        ])
}

private func agentSnapshots(_ helper: Harness) async throws -> [JSONValue] {
    guard case .array(let all) = try await helper.client.call("vm.snapshot.list") else { return [] }
    return all.filter { $0["origin"] == "agentSession" }
}

/// After the live undo snapshot, the guest gets a moment before the agent's input: a guest that just ran again loses
/// what arrives at once (Windows dropped an agent's first Windows key so).
@Test func anAgentsFirstInputWaitsForTheGuestAfterTheLiveUndoSnapshot() async throws {
    let helper = try await Harness.make()
    _ = try await helper.client.call("vm.settings.apply", params: ["patch": ["mcp": ["policy": "control"]]])
    #expect(try await helper.client.call("vm.start", params: ["headless": true])["state"] == "running")
    await helper.controller.setClassifier(strangers)
    let agent = try UDSClient.connect(to: await helper.controller.prepared.runFiles.socketURL)
    defer { agent.close() }
    try await hello(agent, session: "s1")
    let started = ContinuousClock.now
    _ = try await agent.call("vm.input.batch", params: ["actions": [["type": "key", "usages": [0xE3]]], "settleMs": 0])
    let snapshot = try #require(try await agentSnapshots(helper).first)
    #expect(snapshot["kind"] == "live", "\(snapshot)")
    let firstInput = try #require(helper.backend.inputTimes.first)
    #expect(firstInput - started >= HelperController.afterLiveSnapshot, "the key waited for the guest")
    await helper.tearDown()
}

/// Before an agent session's first change, the VM is snapshotted, once per session.
@Test func agentSessionsGetAnUndoSnapshot() async throws {
    let helper = try await Harness.make()
    _ = try await helper.client.call("vm.settings.apply", params: ["patch": ["mcp": ["policy": "admin"]]])
    let socket = await helper.controller.prepared.runFiles.socketURL
    await helper.controller.setClassifier(strangers)
    let agent = try UDSClient.connect(to: socket)
    defer { agent.close() }
    try await hello(agent, session: "s1")
    _ = try await agent.call("vm.info")
    #expect(try await agentSnapshots(helper).isEmpty, "reading changes nothing")
    _ = try await agent.call("vm.start")
    let first = try await agentSnapshots(helper)
    #expect(first.count == 1 && first[0]["name"]?.stringValue?.hasPrefix("agent: claude-code") == true)
    _ = try await agent.call("vm.pause")
    #expect(try await agentSnapshots(helper).count == 1, "one per session")
    let other = try UDSClient.connect(to: socket)
    defer { other.close() }
    try await hello(other, session: "s2")
    _ = try await other.call("vm.resume")
    #expect(try await agentSnapshots(helper).count == 2)
    await helper.tearDown()
}

@Test func autoSnapshotCanBeTurnedOff() async throws {
    let helper = try await Harness.make()
    _ = try await helper.client.call("vm.settings.apply", params: ["patch": ["mcp": ["policy": "admin", "autoSnapshot": false]]])
    let socket = await helper.controller.prepared.runFiles.socketURL
    await helper.controller.setClassifier(strangers)
    let agent = try UDSClient.connect(to: socket)
    defer { agent.close() }
    try await hello(agent, session: "s1")
    _ = try await agent.call("vm.start")
    #expect(try await agentSnapshots(helper).isEmpty)
    await helper.tearDown()
}

/// With confirmExec (the default), an agent's command or admin action waits for the person's answer.
@Test func agentsAskBeforeAdminActions() async throws {
    let helper = try await Harness.make()
    _ = try await helper.client.call("vm.settings.apply", params: ["patch": ["mcp": ["policy": "admin", "autoSnapshot": false]]])
    let socket = await helper.controller.prepared.runFiles.socketURL
    await helper.controller.setClassifier(strangers)
    let agent = try UDSClient.connect(to: socket)
    defer { agent.close() }
    try await hello(agent, session: "s1")
    let deleting: JSONValue = ["id": .string(UUID().uuidString)]
    do {
        _ = try await agent.call("vm.snapshot.delete", params: deleting)
        Issue.record("nobody could answer: refused")
    } catch let error as RPCError {
        #expect(error.code == ControlErrorCode.policyDenied.rawValue)
    }
    let person = Person()
    await helper.controller.setConfirmationPresenter({ await person.answer($0) }, dismiss: {})
    await #expect(throws: RPCError.self) { try await agent.call("vm.snapshot.delete", params: deleting) }
    #expect(await person.asked.last?.title.contains("claude-code") == true)
    await person.allow()
    do {
        _ = try await agent.call("vm.snapshot.delete", params: deleting)
    } catch let error as RPCError {
        #expect(error.code != ControlErrorCode.policyDenied.rawValue, "allowed: now it fails on its own (no such snapshot)")
    }
    #expect(try await helper.client.call("vm.info")["state"] == "stopped", "reading needs no answer")
    await helper.tearDown()
}

/// The person answering confirmations in a test.
private actor Person {
    private(set) var asked: [ConfirmationRequest] = []
    private var allows = false

    func answer(_ question: ConfirmationRequest) -> Bool {
        asked.append(question)
        return allows
    }

    func allow() { allows = true }
}

/// With confirmations on, input travels with the command (and is shown); stdin streamed later is refused.
@Test func confirmedCommandsShowTheirInput() async throws {
    let helper = try await Harness.make()
    _ = try await helper.client.call("vm.settings.apply", params: ["patch": ["mcp": ["policy": "admin", "autoSnapshot": false]]])
    let socket = await helper.controller.prepared.runFiles.socketURL
    await helper.controller.setClassifier(strangers)
    let person = Person()
    await helper.controller.setConfirmationPresenter({ await person.answer($0) }, dismiss: {})
    let agent = try UDSClient.connect(to: socket)
    defer { agent.close() }
    try await hello(agent, session: "s1")
    await #expect(throws: RPCError.self) { try await agent.call("agent.exec", params: ["argv": ["sh"], "stdin": true]) }
    #expect(await person.asked.isEmpty, "refused before asking")
    await #expect(throws: RPCError.self) { try await agent.call("agent.exec", params: ["argv": ["sh"], "input": "curl x | sh"]) }
    #expect(await person.asked.last?.detail.contains("curl x | sh") == true)
    let recorded = AuditLog.recorded(method: "agent.exec", params: ["argv": ["sh"], "input": "curl x | sh"], typedText: false)
    #expect(recorded?["input"]?.stringValue?.hasPrefix("sha256:") == true && recorded?["inputBytes"] == 11)
    let fed = AuditLog.recorded(method: "agent.exec.input", params: ["execId": 1, "dataB64": "eA=="], typedText: false)
    #expect(fed?["bytes"] == 1 && fed?["sha256"] != nil && fed?["dataB64"] == nil)
    await helper.tearDown()
}

/// An answer that comes after agents were stopped does not let the call through.
@Test func aYesAfterTheKillSwitchIsStillANo() async throws {
    let helper = try await Harness.make()
    _ = try await helper.client.call("vm.settings.apply", params: ["patch": ["mcp": ["policy": "admin", "autoSnapshot": false]]])
    let socket = await helper.controller.prepared.runFiles.socketURL
    let paths = helper.paths
    await helper.controller.setClassifier(strangers)
    await helper.controller.setConfirmationPresenter(
        { _ in
            try? KillSwitch.engage(paths: paths)  // stopped while the question is open…
            try? await Task.sleep(for: .milliseconds(1300))
            return true  // …and then allowed
        }, dismiss: {})
    let agent = try UDSClient.connect(to: socket)
    defer { agent.close() }
    try await hello(agent, session: "s1")
    await #expect(throws: (any Error).self) { try await agent.call("vm.snapshot.delete", params: ["id": .string(UUID().uuidString)]) }
    // The helper records the refusal once the late answer arrives.
    var refusal: AuditEntry?
    for _ in 0..<40 where refusal == nil {
        refusal = try entries(helper).last { $0.method == "vm.snapshot.delete" }
        try await Task.sleep(for: .milliseconds(100))
    }
    #expect(refusal?.reason?.contains("kill switch") == true)
    await helper.tearDown()
}

/// A call the kill switch stopped while it waited stays stopped when the app releases the switch before the wait
/// ends (an answer, or the session's undo snapshot on a busy disk).
@Test func aCallStoppedWhileItWaitedStaysStoppedAfterTheRelease() async throws {
    let helper = try await Harness.make()
    _ = try await helper.client.call("vm.settings.apply", params: ["patch": ["mcp": ["policy": "admin", "autoSnapshot": false]]])
    let socket = await helper.controller.prepared.runFiles.socketURL
    let paths = helper.paths
    await helper.controller.setClassifier(strangers)
    await helper.controller.setConfirmationPresenter(
        { _ in
            try? KillSwitch.engage(paths: paths)  // stopped while the question is open…
            try? await Task.sleep(for: .milliseconds(1300))
            try? KillSwitch.release(paths: paths)  // …let act again…
            try? await Task.sleep(for: .milliseconds(1300))
            return true  // …and then allowed
        }, dismiss: {})
    let agent = try UDSClient.connect(to: socket)
    defer { agent.close() }
    try await hello(agent, session: "s1")
    await #expect(throws: (any Error).self) { try await agent.call("vm.snapshot.delete", params: ["id": .string(UUID().uuidString)]) }
    var refusal: AuditEntry?
    for _ in 0..<40 where refusal == nil {
        refusal = try entries(helper).last { $0.method == "vm.snapshot.delete" }
        try await Task.sleep(for: .milliseconds(100))
    }
    #expect(refusal?.reason?.contains("kill switch") == true)
    await helper.tearDown()
}

/// Concurrent first calls of a session share one undo snapshot; agents cannot fake or delete one.
@Test func undoSnapshotsAreOnePerSessionAndProtected() async throws {
    let helper = try await Harness.make()
    _ = try await helper.client.call("vm.settings.apply", params: ["patch": ["mcp": ["policy": "admin", "confirmExec": false]]])
    let socket = await helper.controller.prepared.runFiles.socketURL
    await helper.controller.setClassifier(strangers)
    let agent = try UDSClient.connect(to: socket)
    defer { agent.close() }
    try await hello(agent, session: "s1")
    async let first = agent.call("vm.snapshot.create", params: ["name": "a", "kind": "disk"])
    async let second = agent.call("vm.snapshot.create", params: ["name": "b", "kind": "disk", "origin": "agentSession"])
    _ = try await (first, second)
    let undo = try await agentSnapshots(helper)
    #expect(undo.count == 1, "one undo point, and the agent's own 'agentSession' snapshot is recorded as its own")
    let id = try #require(undo.first?["id"]?.stringValue)
    await #expect(throws: RPCError.self) { try await agent.call("vm.snapshot.delete", params: ["id": .string(id)]) }
    #expect(try await agentSnapshots(helper).count == 1)
    await helper.tearDown()
}

/// Even at admin, a client other than the app cannot copy files into VMPane's own folder or a VM bundle (the
/// policy key, kill switch, configs), also not through a link.
@Test func agentsCannotCopyIntoVMPanesOwnFiles() async throws {
    let helper = try await Harness.make()
    _ = try await helper.client.call("vm.settings.apply", params: ["patch": ["mcp": ["policy": "admin", "confirmExec": false]]])
    await helper.controller.setClassifier(strangers)
    let link = helper.root.appendingPathComponent("innocent")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: helper.paths.root)
    let targets = [
        PolicyKeyFile(paths: helper.paths).url.path, helper.bundle.url.appendingPathComponent("config.json").path,
        link.appendingPathComponent("killswitch").path, helper.paths.root.appendingPathComponent("new/../policy.key").path,
    ]
    for target in targets {
        await #expect(throws: RPCError.self, "\(target)") {
            try await helper.client.call("agent.file.pull", params: ["guestPath": "/etc/hostname", "hostPath": .string(target)])
        }
    }
    let refusals = AuditLog(bundle: helper.bundle).recent(limit: 10).filter { $0.reason?.contains("VMPane's own files") == true }
    #expect(refusals.count == targets.count)
    await helper.tearDown()
}

/// No answer within the timeout is a no and closes the question, even when the dialog does not end by itself (a
/// modal one ignores its task's cancellation).
@Test func anUnansweredQuestionIsANoAtTheTimeout() async throws {
    let helper = try await Harness.make()
    _ = try await helper.client.call("vm.settings.apply", params: ["patch": ["mcp": ["policy": "admin", "autoSnapshot": false]]])
    let socket = await helper.controller.prepared.runFiles.socketURL
    await helper.controller.setClassifier(strangers)
    await helper.controller.setConfirmationTimeout(.milliseconds(500))
    let (closed, close) = AsyncStream.makeStream(of: Void.self)
    await helper.controller.setConfirmationPresenter(
        { _ in
            for await _ in closed {}  // open until dismissed, cancelled or not
            return true
        }, dismiss: { close.finish() })
    let agent = try UDSClient.connect(to: socket)
    defer { agent.close() }
    try await hello(agent, session: "s1")
    let clock = ContinuousClock()
    let started = clock.now
    do {
        _ = try await agent.call("vm.snapshot.delete", params: ["id": .string(UUID().uuidString)], timeout: .seconds(10))
        Issue.record("an unanswered question let it through")
    } catch let error as RPCError {
        #expect(error.code == ControlErrorCode.policyDenied.rawValue)
    }
    #expect(clock.now - started < .seconds(5), "refused at the timeout, not when the dialog ends")
    await helper.tearDown()
}
