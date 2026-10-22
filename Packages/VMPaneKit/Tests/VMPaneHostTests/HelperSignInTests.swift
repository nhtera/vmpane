import AppKit
import CoreGraphics
import CryptoKit
import Foundation
import Testing
import VMPaneCore

@testable import VMPaneControl
@testable import VMPaneHost

/// A classifier that sees every peer as an unknown process (an agent's).
private let strangers = PeerClassifier(
    selfPID: -1, selfTeamID: nil, selfIsAdHoc: true, identify: { _ in nil }, satisfies: { _, _ in false })

private let secret = "s3cret-Pass!word"

/// A white screen with a password prompt on it, as a lock screen shows once woken.
private func lockScreen(prompt: String = "Password") -> CGImage? {
    let width = 1024, height = 768
    guard
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    (prompt as NSString).draw(
        at: NSPoint(x: 420, y: 360), withAttributes: [.font: NSFont.systemFont(ofSize: 36), .foregroundColor: NSColor.black])
    NSGraphicsContext.current = nil
    return context.makeImage()
}

/// The guest side: `hello` with the session.state cap, then `states` in turn for each `session.state` (the last
/// one stays).
private func connectGuest(_ helper: Harness, states: [String]) async throws -> (FakeAgent, Task<Void, Never>) {
    let (agent, hostFD) = try FakeAgent.pair()
    helper.backend.connectAgent(hostFD)
    try agent.hello(caps: ["exec", "session.state"])
    _ = await agent.nextMessage()  // the hello's answer
    let answering = Task.detached {
        var left = states
        while let message = await agent.nextMessage(within: 30) {
            guard case .request(let request) = message, let id = request.id else { continue }
            let state = left.count > 1 ? left.removeFirst() : left.first ?? "unknown"
            let result: JSONValue = request.method == AgentMethod.sessionState ? ["state": .string(state)] : [:]
            try? agent.send(.response(RPCResponse(id: id, result: result)))
        }
    }
    try await Task.sleep(for: .milliseconds(200))
    return (agent, answering)
}

/// A running VM at `level` that lets agents sign in (typed text recorded: the password must still not be), its password kept.
private func signInVM(level: String = "control", signIn: Bool = true) async throws -> Harness {
    let helper = try await Harness.make(os: .windows)
    _ = try await helper.client.call(
        "vm.settings.apply",
        params: ["patch": ["mcp": ["policy": .string(level), "auditTypedText": true, "autoSnapshot": false, "signIn": .bool(signIn)]]])
    #expect(try await helper.client.call("vm.start", params: ["headless": true])["state"] == "running")
    let config = try ConfigStore.load(helper.bundle)
    try GuestCredentials.store(paths: helper.paths).save(secret, for: config.id, name: config.name)
    helper.backend.image = lockScreen()
    await helper.controller.setClassifier(strangers)
    return helper
}

private func auditText(_ helper: Harness) -> String {
    (try? String(contentsOf: helper.bundle.url.appendingPathComponent("logs/mcp-audit.jsonl"), encoding: .utf8)) ?? ""
}

@Test func signInTypesTheKeptPasswordIntoTheGuestOnly() async throws {
    let helper = try await signInVM()
    let (_, answering) = try await connectGuest(helper, states: ["locked", "locked", "unlocked"])
    defer { answering.cancel() }
    let reply = try await helper.client.call("vm.signIn", timeout: .seconds(60))
    #expect(reply["verified"]?["status"] == "signed_in")
    let inputs = helper.backend.recordedCalls.filter { $0.hasPrefix("input.") }
    #expect(inputs.contains("input.text(\"\(secret)\")"), "typed into the guest")
    #expect(inputs.last == "input.key(usage: 40, down: false)", "then Return")
    #expect(inputs.contains { $0.hasPrefix("input.pointer") && $0.hasSuffix("buttons: 1)") }, "the field clicked")
    // Never in a reply or the audit log, typed text recorded or not; nor its hash.
    let digest = SHA256.hash(data: Data(secret.utf8)).map { String(format: "%02x", $0) }.joined()
    #expect(!"\(reply)".contains(secret))
    #expect(!auditText(helper).contains(secret) && !auditText(helper).contains(digest))
    #expect(auditText(helper).contains("vm.signIn"))
    await helper.tearDown()
}

@Test func signInIsRefusedUnlessTheSystemSaysTheGuestIsLocked() async throws {
    // The guest cannot tell (a Linux user's own lock screen): refused, nothing typed.
    let helper = try await signInVM()
    let (_, answering) = try await connectGuest(helper, states: ["unknown"])
    await #expect(throws: RPCError.self) { _ = try await helper.client.call("vm.signIn", timeout: .seconds(30)) }
    #expect(!helper.backend.recordedCalls.contains { $0.hasPrefix("input.") })
    answering.cancel()
    await helper.tearDown()

    // Signed in already: nothing to do.
    let signedIn = try await signInVM()
    let (_, answering2) = try await connectGuest(signedIn, states: ["unlocked"])
    #expect(try await signedIn.client.call("vm.signIn", timeout: .seconds(30))["verified"]?["status"] == "already_signed_in")
    #expect(!signedIn.backend.recordedCalls.contains { $0.hasPrefix("input.") })
    answering2.cancel()
    await signedIn.tearDown()
}

@Test func signInNeedsTheSettingAndAPasswordField() async throws {
    let off = try await signInVM(signIn: false)
    let (_, answering) = try await connectGuest(off, states: ["locked"])
    do {
        _ = try await off.client.call("vm.signIn", timeout: .seconds(30))
        Issue.record("signed in with the setting off")
    } catch let error as RPCError {
        #expect(error.code == ControlErrorCode.policyDenied.rawValue)
    }
    answering.cancel()
    await off.tearDown()

    // No password field on the screen (a user list, or a PIN): refused before anything is typed.
    for prompt in ["Choose a user", "PIN"] {
        let helper = try await signInVM()
        helper.backend.image = lockScreen(prompt: prompt)
        let (_, answering) = try await connectGuest(helper, states: ["locked"])
        await #expect(throws: RPCError.self) { _ = try await helper.client.call("vm.signIn", timeout: .seconds(30)) }
        #expect(!helper.backend.recordedCalls.contains { $0.hasPrefix("input.text") }, "\(prompt)")
        answering.cancel()
        await helper.tearDown()
    }
}

@Test func theFileStoreKeepsPasswordsPrivately() throws {
    let root = URL(fileURLWithPath: "/tmp/vp-cred-\(UUID().uuidString.prefix(8))")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = GuestCredentials.store(paths: VMPanePaths(root: root))
    let vm = UUID()
    #expect(try store.password(for: vm) == nil)
    try store.save("first", for: vm, name: "V")
    try store.save("second", for: vm, name: "V")
    #expect(try store.password(for: vm) == "second")
    let file = root.appendingPathComponent("sign-in/\(vm.uuidString.lowercased())")
    #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int == 0o600)
    try store.delete(for: vm)
    try store.delete(for: vm)
    #expect(try store.password(for: vm) == nil)
}

@Test func oneSignInAtATime() async throws {
    let helper = try await signInVM()
    let (_, answering) = try await connectGuest(helper, states: ["locked", "locked", "locked", "unlocked"])
    defer { answering.cancel() }
    let socket = await helper.controller.prepared.runFiles.socketURL
    let other = try UDSClient.connect(to: socket)
    defer { other.close() }
    async let first = Result(catching: { try await helper.client.call("vm.signIn", timeout: .seconds(60)) })
    try await Task.sleep(for: .milliseconds(100))
    let second = await Result(catching: { try await other.call("vm.signIn", timeout: .seconds(60)) })
    let busy = try #require(second.failure as? RPCError)
    #expect(busy.code == ControlErrorCode.busy.rawValue)
    // Agents' input is held meanwhile.
    let typed = await Result(catching: { try await other.call("vm.input.text", params: ["text": "x"]) })
    #expect((typed.failure as? RPCError)?.code == ControlErrorCode.busy.rawValue)
    #expect(try await first.get()["verified"]?["status"] == "signed_in")
    await helper.tearDown()
}

/// A desktop app an agent opened is ended by the kill switch, after the agent's connection closed too.
@Test func theKillSwitchEndsDesktopAppsOfAgentsThatLeft() async throws {
    let helper = try await Harness.make()
    _ = try await helper.client.call(
        "vm.settings.apply", params: ["patch": ["mcp": ["policy": "exec", "confirmExec": false, "autoSnapshot": false]]])
    #expect(try await helper.client.call("vm.start", params: ["headless": true])["state"] == "running")
    let (agent, hostFD) = try FakeAgent.pair()
    helper.backend.connectAgent(hostFD)
    try agent.hello(caps: ["exec", "desktop"])
    _ = await agent.nextMessage()
    let signals = AsyncStream.makeStream(of: JSONValue?.self)
    let answering = Task.detached {
        while let message = await agent.nextMessage(within: 30) {
            guard case .request(let request) = message, let id = request.id else { continue }
            let result: JSONValue = request.method == AgentMethod.execStart ? ["execId": 7, "pid": 4242] : [:]
            if request.method == AgentMethod.execSignal { signals.continuation.yield(request.params) }
            try? agent.send(.response(RPCResponse(id: id, result: result)))
        }
    }
    defer { answering.cancel() }
    try await Task.sleep(for: .milliseconds(200))
    await helper.controller.setClassifier(strangers)
    let socket = await helper.controller.prepared.runFiles.socketURL
    let byAgent = try UDSClient.connect(to: socket)
    let opened = try await byAgent.call("agent.exec", params: ["argv": ["charmap.exe"], "desktop": true])
    #expect(opened["launched"] == true && opened["pid"] == 4242)
    byAgent.close()  // the agent leaves; its app stays
    try await Task.sleep(for: .milliseconds(200))
    let stopper = try UDSClient.connect(to: socket)
    defer { stopper.close() }
    _ = try await stopper.call("mcp.disableAll")
    var iterator = signals.stream.makeAsyncIterator()
    let signal = await iterator.next()
    #expect(signal??["execId"] == 7 && signal??["signal"] == "kill")
    await helper.tearDown()
}

extension Result {
    fileprivate var failure: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }

    fileprivate init(catching body: () async throws -> Success) async where Failure == any Error {
        do { self = .success(try await body()) } catch { self = .failure(error) }
    }
}

/// At levels that run commands the person is asked first; a no (or no answer) refuses before anything is typed.
@Test func atRunCommandsThePersonIsAskedFirst() async throws {
    let helper = try await signInVM(level: "exec")
    let (_, answering) = try await connectGuest(helper, states: ["locked", "locked", "unlocked"])
    defer { answering.cancel() }
    let asked = AsyncStream.makeStream(of: ConfirmationRequest.self)
    await helper.controller.setConfirmationPresenter(
        { question in
            asked.continuation.yield(question)
            return false
        }, dismiss: {})
    do {
        _ = try await helper.client.call("vm.signIn", timeout: .seconds(60))
        Issue.record("signed in without the person's yes")
    } catch let error as RPCError {
        #expect(error.code == ControlErrorCode.policyDenied.rawValue)
    }
    var questions = asked.stream.makeAsyncIterator()
    let question = await questions.next()
    #expect(question?.title.contains("sign in") == true && question?.detail.contains(secret) == false)
    #expect(!helper.backend.recordedCalls.contains { $0.hasPrefix("input.") })
    await helper.tearDown()
}
