import CoreGraphics
import Foundation
import VMPaneControl
import VMPaneCore

/// `vm.signIn`: signs a locked guest in with the password kept for it (`GuestCredentials`), which the agent never
/// sees. Only when every check holds, in order: the VM's "Let agents sign in" (inside the policy's tag); the guest's
/// root service reporting its login screen or a locked session (`session.state`, which the signed-in user cannot
/// set); at levels that run commands, the person's yes; a password field on the screen once woken (OCR). The
/// password goes from the store to the backend's typing here, never through a request, so never into the audit
/// log, a log or a reply. One attempt per call; agents' input waits meanwhile (`signingIn`).
extension HelperController {
    static let signInTimeout: Duration = .seconds(30)

    private enum Usage {
        static let space: UInt16 = 0x2C
        static let backspace: UInt16 = 0x2A
        static let a: UInt16 = 0x04
        static let leftControl: UInt16 = 0xE0
        static let leftCommand: UInt16 = 0xE3
        static let leftShift: UInt16 = 0xE1
        /// Left and right control, shift, option, command.
        static let modifiers: [UInt16] = Array(0xE0...0xE7)
    }

    func signIn(from connection: ControlConnection) async -> Result<JSONValue, RPCError> {
        let caller = identity(of: connection)
        let admitted = agentGeneration
        // Claimed before the first wait, for the whole call: one sign-in at a time, and agents' input held until it ends.
        guard !signingIn else { return .failure(RPCError(.busy, "VMPane is signing the VM in already")) }
        signingIn = true
        defer { signingIn = false }
        do {
            guard let backend, state == .running else { throw RPCError(.invalidState, "the VM is \(state.rawValue)") }
            guard let agent = try await signInAgent() else { return .success(["verified": ["status": "already_signed_in"]]) }
            let password = try await keptPassword(backend)
            if effectivePolicy().level >= .exec {
                let question = ConfirmationRequest(
                    title: "\(Self.who(caller)) wants to sign in to \(config.name)",
                    detail: "VMPane types the password kept for this VM. The agent does not see it.")
                guard await ask(question) else {
                    throw RPCError(.policyDenied, "the person at this Mac did not allow it (\(question.title))")
                }
            }
            try checkStillAllowed(admitted, caller)
            return .success(try await typePassword(password, backend: backend, agent: agent, admitted: admitted, caller: caller))
        } catch let error as RPCError {
            return .failure(error)
        } catch let error as AgentConnection.ConnectionError {
            if case .rpc(let agentError) = error { return .failure(RPCError(.agentUnavailable, "the guest tools: \(agentError.message)")) }
            return .failure(RPCError(.agentUnavailable, error.description))
        } catch let error as GuestCredentialError {
            return .failure(RPCError(.internalError, error.description))
        } catch {
            return .failure(RPCError(.internalError, ErrorText.readable(error)))
        }
    }

    /// The guest agent, when the VM lets agents sign in and its root service reports the login screen or a locked
    /// session; nil when it reports a signed-in one.
    private func signInAgent() async throws -> AgentConnection? {
        guard effectivePolicy().signIn else {
            throw RPCError(
                .policyDenied, "agents may not sign in to \(config.name): the person can allow it in its settings (AI agents)")
        }
        guard let agent = await agentHub.waitForConnection(timeout: Self.agentWait) else {
            throw RPCError(.agentUnavailable, "the guest agent is not connected")
        }
        guard await agentHub.status.peer?.hello.caps?.contains(AgentCap.sessionState) == true else {
            throw RPCError(.agentUnavailable, "Update the guest tools to let agents sign in")
        }
        switch try await Self.sessionState(agent) {
        case .greeter, .locked: return agent
        case .unlocked: return nil
        case .unknown:
            throw RPCError(
                .invalidState, "the guest cannot tell whether it is locked (its own lock screen, or no screen): sign in is refused")
        }
    }

    /// The password kept for this VM, if VMPane can type it. Read off the actor: the Keychain can be slow.
    private func keptPassword(_ backend: VMBackend) async throws -> String {
        let (store, id) = (GuestCredentials.store(paths: prepared.runFiles.paths), config.id)
        guard let password = try await Blocking.run({ try store.password(for: id) }), !password.isEmpty else {
            throw RPCError(.invalidState, "no password is kept for \(config.name): the person can enter it in its settings (AI agents)")
        }
        guard backend.untypable(in: password) == nil else {
            throw RPCError(.invalidParams, "the kept password has a character VMPane cannot type (US keyboard layout)")
        }
        return password
    }

    /// Holds agents' input, wakes the screen, finds the password field, types into it and waits for the guest to
    /// say it is signed in.
    private func typePassword(
        _ password: String, backend: VMBackend, agent: AgentConnection, admitted: Int, caller: CallerIdentity
    ) async throws -> JSONValue {
        // Agents' input already under way ends first (a batch, a long text).
        while batching || inputsInFlight > 0 {
            try checkStillAllowed(admitted, caller)
            try await Task.sleep(for: .milliseconds(20))
        }
        for usage in Usage.modifiers { try await backend.send(.key(usage: usage, down: false)) }
        let field = try await wakeToPasswordField(backend, admitted: admitted, caller: caller)
        // Still the system's login or lock screen, after the person's answer and the wait.
        guard [.greeter, .locked].contains(try await Self.sessionState(agent)) else {
            throw RPCError(.invalidState, "the guest is no longer at its login or lock screen")
        }
        try await backend.send(.pointer(x: field.midX, y: field.midY, buttons: 0))
        try await backend.send(.pointer(x: field.midX, y: field.midY, buttons: 1))
        try await Task.sleep(for: .milliseconds(40))
        try await backend.send(.pointer(x: field.midX, y: field.midY, buttons: 0))
        try await Task.sleep(for: .milliseconds(200))
        try await clearField(backend)
        let characters = Array(password)
        let piece = max(1, Int(Self.batchStopCheck / backend.typingPace))
        for start in stride(from: 0, to: characters.count, by: piece) {
            try checkStillAllowed(admitted, caller)
            try await backend.send(.text(String(characters[start..<min(start + piece, characters.count)])))
        }
        try checkStillAllowed(admitted, caller)
        try await tap([Self.returnUsage], backend: backend)
        let deadline = ContinuousClock.now + Self.signInTimeout
        while ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(500))
            try checkStillAllowed(admitted, caller)
            if try await Self.sessionState(agent) == .unlocked {
                Self.log.notice("sign-in: the guest reports a signed-in session")
                return ["verified": ["status": "signed_in"]]
            }
        }
        throw RPCError(
            .invalidState,
            "the guest did not sign in within \(Self.signInTimeout.components.seconds) s (a wrong password, or a guest keyboard layout "
                + "other than US)")
    }

    /// The password field, waking the screen as needed: the screen as it is first; then Shift, which wakes a
    /// sleeping display and types nothing; then Space, which lifts a Windows lock screen's curtain (or picks a focused
    /// user tile) but types into a field that already has the focus (the macOS lock screen), hiding its prompt, so the
    /// field is emptied again before looking.
    private func wakeToPasswordField(_ backend: VMBackend, admitted: Int, caller: CallerIdentity) async throws -> CGRect {
        var field = try await passwordField()
        for step in 0..<4 where field == nil {
            switch step {
            case 0: try await tap([Usage.leftShift], backend: backend)
            case 1:
                try await tap([Usage.space], backend: backend)
                try await Task.sleep(for: .milliseconds(500))
                try await clearField(backend)
            default: break
            }
            try await Task.sleep(for: .milliseconds(1500))
            try checkStillAllowed(admitted, caller)
            field = try await passwordField()
        }
        guard let field else {
            throw RPCError(.invalidState, "no password field is on the VM's screen (choose the user first, then sign in again)")
        }
        return field
    }

    /// The password field on the screen (OCR): where its prompt is. A PIN prompt is refused; the text read never
    /// leaves this function (counts only in the log).
    private func passwordField() async throws -> CGRect? {
        guard let image = await captureImage() else { throw RPCError(.backendUnavailable, "the VM's display cannot be read now") }
        let lines = try await Blocking.run { try ScreenText.recognize(image) }
        let texts = lines.map { GuestText.clean($0.text, maxLength: 80).lowercased().trimmingCharacters(in: .whitespaces) }
        Self.log.info("sign-in: \(lines.count) lines on the screen")
        if texts.contains(where: { $0.split(whereSeparator: { !$0.isLetter }).contains("pin") }) {
            throw RPCError(.invalidState, "the guest asks for a PIN: VMPane signs in with the account's password only")
        }
        let prompt = texts.firstIndex { Self.passwordPrompts.contains($0.trimmingCharacters(in: CharacterSet(charactersIn: ":. "))) }
        return prompt.map { lines[$0].rect }
    }

    /// The prompts of the lock and login screens (Windows, macOS, GNOME), English.
    static let passwordPrompts: Set<String> = ["password", "enter password", "enter your password", "type your password"]

    /// Agents' input while the helper types a sign-in: refused, so it cannot land in the password field.
    func heldForSignIn(_ method: ControlMethod?, _ connection: ControlConnection) -> RPCError? {
        let input: Set<ControlMethod> = [.vmInputKey, .vmInputText, .vmInputPointer, .vmInputScroll, .vmInputBatch, .vmSignIn]
        guard signingIn, let method, input.contains(method), identity(of: connection).identity != .ui else { return nil }
        return RPCError(.busy, "VMPane is signing the VM in; try again in a moment")
    }

    static func sessionState(_ agent: AgentConnection) async throws -> AgentSessionState {
        let reply = try await agent.call(AgentMethod.sessionState, timeout: .seconds(5))
        return (try? RPCParams.decode(AgentSessionStateResult.self, from: reply.result).get())?.state ?? .unknown
    }

    private func checkStillAllowed(_ admitted: Int, _ caller: CallerIdentity) throws {
        if agentInputStopped(since: admitted, caller) { throw inputStopError }
    }

    /// Select all and delete in the focused field.
    private func clearField(_ backend: VMBackend) async throws {
        try await tap([config.os == .macos ? Usage.leftCommand : Usage.leftControl, Usage.a], backend: backend)
        try await tap([Usage.backspace], backend: backend)
    }

    /// Keys pressed in order and released in reverse.
    private func tap(_ usages: [UInt16], backend: VMBackend) async throws {
        for usage in usages { try await backend.send(.key(usage: usage, down: true)) }
        for usage in usages.reversed() { try await backend.send(.key(usage: usage, down: false)) }
        try await Task.sleep(for: .milliseconds(60))
    }
}
