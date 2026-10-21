import CoreGraphics
import Foundation
import VMPaneControl
import VMPaneCore

struct BatchPoint: Decodable, Sendable {
    var x: Double
    var y: Double
}

/// One action. Pointer coordinates are guest pixels; key usages are USB HID (keyboard page).
struct BatchAction: Decodable, Sendable {
    var type: String
    var usages: [UInt16]?
    var text: String?
    var submit: Bool?
    var x: Double?
    var y: Double?
    var button: String?
    var count: Int?
    var modifiers: [UInt16]?
    var from: BatchPoint?
    var to: BatchPoint?
    var dx: Double?
    var dy: Double?
    var milliseconds: Int?

    enum CodingKeys: String, CodingKey {
        case type, usages, text, submit, x, y, button, count, modifiers, from, to, dx, dy
        case milliseconds = "ms"
    }
}

struct BatchParams: Decodable, Sendable {
    var actions: [BatchAction]
    var stopOnError: Bool?
    var settleMs: Int?
    var verify: Bool?
}

/// `vm.input.batch`: a sequence of input actions in one request. Each action is held to the VM's policy and audited
/// as the single request it stands for (`vm.input.key/text/pointer/scroll`); afterwards the screen is watched until
/// it settles, and the reply says whether it changed (`ScreenDiff`). A stop (the kill switch, the client gone) takes
/// effect between actions, between pieces of long text, inside waits and between captures.
extension HelperController {
    public func setDisplaySource(_ source: GuestDisplaySource) { displaySource = source }

    static let batchMaxActions = 50
    /// All `wait` actions of a batch together, in milliseconds.
    static let batchMaxWaitMs = 30_000
    static let batchMaxSettleMs = 10_000
    /// The longest stretch of input between two checks for a stop: text is typed in pieces this long.
    static let batchStopCheck = Duration.milliseconds(100)
    /// How often the screen is captured while it settles (more slowly when a capture takes longer).
    static let settlePoll = Duration.milliseconds(75)
    /// Return, typed after text with `submit`.
    static let returnUsage: UInt16 = 0x28

    private struct Stopped: Error {}

    static let stoppedReason = "AI agents are stopped (VMPane's kill switch)"

    func inputBatch(_ params: JSONValue?, from connection: ControlConnection) async -> Result<JSONValue, RPCError> {
        guard let backend else { return .failure(RPCError(.backendUnavailable, "no backend for this VM")) }
        guard state == .running || state == .paused else { return .failure(RPCError(.invalidState, "the VM is \(state.rawValue)")) }
        let batch: BatchParams
        switch RPCParams.decode(BatchParams.self, from: params) {
        case .success(let decoded): batch = decoded
        case .failure(let error): return .failure(error)
        }
        if let problem = Self.batchProblem(batch) { return .failure(RPCError(.invalidParams, problem)) }
        guard case .array(let raw)? = params?["actions"] else { return .failure(RPCError(.invalidParams, "actions must be an array")) }
        let caller = identity(of: connection)
        let admitted = agentGeneration
        // One batch at a time on a VM: another's held keys and screen changes would mix into this one's.
        while batching {
            if agentsStopped(since: admitted, caller) { return .failure(RPCError(.policyDenied, Self.stoppedReason)) }
            try? await Task.sleep(for: .milliseconds(20))
        }
        batching = true
        defer { batching = false }
        let before = batch.verify == false ? nil : await captureFrame()?.frame
        var results: [JSONValue] = []
        for (index, action) in batch.actions.enumerated() {
            if agentsStopped(since: admitted, caller) {
                return .failure(RPCError(.policyDenied, Self.stoppedReason, data: ["results": .array(results)]))
            }
            let failure = await runAction(action, params: raw[index], caller: caller, admitted: admitted, backend: backend)
            if let failure, failure.message == Self.stoppedReason {
                results.append(["i": .int(Int64(index)), "ok": false, "error": .string(failure.message), "code": .int(Int64(failure.code))])
                return .failure(RPCError(.policyDenied, Self.stoppedReason, data: ["results": .array(results)]))
            }
            let result: JSONValue = ["i": .int(Int64(index)), "ok": .bool(failure == nil)]
            results.append(failure.map { result.adding("error", .string($0.message)).adding("code", .int(Int64($0.code))) } ?? result)
            if failure != nil, batch.stopOnError != false { break }
        }
        var reply = await settle(
            from: before, settleMs: batch.settleMs ?? 300, unverified: batch.verify == false ? "not_verified" : "no_display",
            admitted: admitted, caller: caller)
        reply["results"] = .array(results)
        return .success(.object(reply))
    }

    /// What is wrong with a batch, checked before any of it runs.
    static func batchProblem(_ batch: BatchParams) -> String? {
        guard !batch.actions.isEmpty else { return "actions is empty" }
        guard batch.actions.count <= batchMaxActions else { return "at most \(batchMaxActions) actions per batch" }
        guard (0...batchMaxSettleMs).contains(batch.settleMs ?? 0) else { return "settleMs is 0…\(batchMaxSettleMs)" }
        guard batch.actions.reduce(0, { $0 + max($1.milliseconds ?? 0, 0) }) <= batchMaxWaitMs else {
            return "the waits of a batch add up to at most \(batchMaxWaitMs / 1000) s"
        }
        for (index, action) in batch.actions.enumerated() {
            let complete: Bool =
                switch action.type {
                case "key": !(action.usages ?? []).isEmpty
                case "text": action.text != nil
                case "click":
                    action.x != nil && action.y != nil && ["left", "right", "middle"].contains(action.button ?? "left")
                        && (1...3).contains(action.count ?? 1)
                case "move": action.x != nil && action.y != nil
                case "drag": action.from != nil && action.to != nil
                case "scroll": true
                case "wait": (action.milliseconds ?? -1) >= 0
                default: false
                }
            guard complete else { return "action \(index) (\(action.type.debugDescription)) is unknown or incomplete" }
        }
        return nil
    }

    /// The single request an action stands for (nil for `wait`): its policy rule and its audit line.
    static func batchMethod(_ type: String) -> ControlMethod? {
        switch type {
        case "key": .vmInputKey
        case "text": .vmInputText
        case "click", "move", "drag": .vmInputPointer
        case "scroll": .vmInputScroll
        default: nil
        }
    }

    /// True once agents have been stopped since `admitted`, or the caller went away (never for the app).
    func agentsStopped(since admitted: Int, _ caller: CallerIdentity) -> Bool {
        caller.identity != .ui && (killSwitchEngaged || agentGeneration != admitted || caller.connection?.isFinished ?? true)
    }

    /// A frame for verification: the helper app's (SPICE, in memory) when it has one, else the backend's; and which.
    func captureFrame() async -> (frame: GrayFrame, source: String)? {
        if let frame = await displaySource?.grayFrame() { return (frame, "helper app") }
        return await backend?.grayFrame().map { ($0, "backend") }
    }

    /// The display at full resolution, from the same sources in the same order.
    func captureImage() async -> CGImage? {
        if let image = await displaySource?.displayImage() { return image }
        return await backend?.displayImage()
    }

    /// Runs one action as the request it stands for: policy, the agent checks, the input, its audit line.
    private func runAction(
        _ action: BatchAction, params: JSONValue, caller: CallerIdentity, admitted: Int, backend: VMBackend
    ) async -> RPCError? {
        let started = ContinuousClock.now
        let request = Self.batchMethod(action.type).map { RPCRequest(id: nil, method: $0.rawValue, params: params) }
        if let request, caller.identity != .ui {
            if let denial = authorize(request, caller) { return denial }
            if let refusal = await agentChecks(request, caller) {
                audit(request, caller, result: .failure(refusal), since: started)
                return refusal
            }
        }
        let result: Result<JSONValue, RPCError>
        do {
            try await perform(action, backend: backend, admitted: admitted, caller: caller)
            result = .success([:])
        } catch is Stopped {
            result = .failure(RPCError(.policyDenied, Self.stoppedReason))
        } catch let error as RPCError {
            result = .failure(error)
        } catch {
            result = .failure(RPCError(.internalError, "input failed: \(error)"))
        }
        if let request, caller.identity != .ui { audit(request, caller, result: result, since: started) }
        if case .failure(let error) = result { return error }
        return nil
    }

    private func perform(_ action: BatchAction, backend: VMBackend, admitted: Int, caller: CallerIdentity) async throws {
        switch action.type {
        case "key":
            try await press(action.usages ?? [], backend: backend)
        case "text":
            // Whole or not at all, as `vm.input.text` is.
            if let character = backend.untypable(in: action.text ?? "") {
                throw RPCError(.invalidParams, "\(String(character).debugDescription) cannot be typed (US keyboard layout)")
            }
            let characters = Array(action.text ?? "")
            let piece = max(1, Int(Self.batchStopCheck / backend.typingPace))
            for start in stride(from: 0, to: characters.count, by: piece) {
                if agentsStopped(since: admitted, caller) { throw Stopped() }
                try await backend.send(.text(String(characters[start..<min(start + piece, characters.count)])))
            }
            if action.submit == true {
                if agentsStopped(since: admitted, caller) { throw Stopped() }
                try await press([Self.returnUsage], backend: backend)
            }
        case "click", "move", "drag":
            try await Self.point(action, backend: backend)
        case "scroll":
            try await backend.send(.scroll(dx: action.dx ?? 0, dy: action.dy ?? 0))
        case "wait":
            try await pause(until: ContinuousClock.now + .milliseconds(action.milliseconds ?? 0), admitted: admitted, caller: caller)
        default:
            break
        }
    }

    /// Keys pressed in order and released in reverse (released too when one fails).
    private func press(_ usages: [UInt16], backend: VMBackend) async throws {
        do {
            for usage in usages { try await backend.send(.key(usage: usage, down: true)) }
        } catch {
            for usage in usages.reversed() { try? await backend.send(.key(usage: usage, down: false)) }
            throw error
        }
        for usage in usages.reversed() { try await backend.send(.key(usage: usage, down: false)) }
    }

    /// A click, a move or a drag (buttons and modifiers released again when it fails).
    private static func point(_ action: BatchAction, backend: VMBackend) async throws {
        func point(_ x: Double?, _ y: Double?, _ buttons: Int) async throws {
            try await backend.send(.pointer(x: x ?? 0, y: y ?? 0, buttons: buttons))
        }
        let modifiers = action.type == "click" ? action.modifiers ?? [] : []
        let end = action.to.map { ($0.x, $0.y) } ?? (action.x ?? 0, action.y ?? 0)
        do {
            for usage in modifiers { try await backend.send(.key(usage: usage, down: true)) }
            switch action.type {
            case "click":
                let bit = ["left": 1, "right": 2, "middle": 4][action.button ?? "left"] ?? 1
                try await point(action.x, action.y, 0)
                for _ in 0..<(action.count ?? 1) {
                    try await point(action.x, action.y, bit)
                    try await Task.sleep(for: .milliseconds(40))
                    try await point(action.x, action.y, 0)
                    try await Task.sleep(for: .milliseconds(60))
                }
            case "drag":
                guard let from = action.from, let to = action.to else { return }
                try await point(from.x, from.y, 0)
                try await point(from.x, from.y, 1)
                for step in 1...10 {
                    let fraction = Double(step) / 10
                    try await point(from.x + (to.x - from.x) * fraction, from.y + (to.y - from.y) * fraction, 1)
                    try await Task.sleep(for: .milliseconds(20))
                }
                try await point(to.x, to.y, 0)
            default:
                try await point(action.x, action.y, 0)
            }
        } catch {
            try? await point(end.0, end.1, 0)
            for usage in modifiers.reversed() { try? await backend.send(.key(usage: usage, down: false)) }
            throw error
        }
        for usage in modifiers.reversed() { try await backend.send(.key(usage: usage, down: false)) }
    }

    /// Sleeps until `deadline` in slices, throwing `Stopped` when agents are stopped meanwhile.
    private func pause(until deadline: ContinuousClock.Instant, admitted: Int, caller: CallerIdentity) async throws {
        while ContinuousClock.now < deadline {
            if agentsStopped(since: admitted, caller) { throw Stopped() }
            try await Task.sleep(for: min(Self.batchStopCheck / 2, deadline - ContinuousClock.now))
        }
    }

    /// Watches the screen after the input: done early once it changed, stayed changed for two captures and held still
    /// between them; otherwise at `settleMs` (at least two captures either way). The reply's `verified` and `screen`.
    private func settle(from before: GrayFrame?, settleMs: Int, unverified: String, admitted: Int, caller: CallerIdentity) async
        -> [String: JSONValue]
    {
        let start = ContinuousClock.now
        let deadline = start + .milliseconds(settleMs)
        func waited() -> JSONValue {
            let elapsed = ContinuousClock.now - start
            return .int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
        }
        let unknown = { (reason: String, waitedMs: JSONValue) -> [String: JSONValue] in
            ["verified": ["status": "unknown", "reason": .string(reason), "settled": false, "waitedMs": waitedMs]]
        }
        guard let before else {
            try? await pause(until: deadline, admitted: admitted, caller: caller)
            return unknown(unverified, waited())
        }
        var interval = Self.settlePoll
        var capturing = Duration.zero
        var source = ""
        var last: GrayFrame?
        var change = ScreenChange(changed: false, ratio: 0, box: nil)
        var persisted = false, still = false, polls = 0
        while polls < 2 || ContinuousClock.now < deadline {
            try? await Task.sleep(for: interval)
            if agentsStopped(since: admitted, caller) { return screen(of: before, unknown("stopped", waited())) }
            let begun = ContinuousClock.now
            guard let (frame, from) = await captureFrame() else { return screen(of: before, unknown("no_display", waited())) }
            source = from
            capturing += ContinuousClock.now - begun
            interval = max(Self.settlePoll, (ContinuousClock.now - begun) * 2)
            let now = ScreenDiff.compare(before, frame)
            persisted = now.changed && change.changed
            still = last.map { !ScreenDiff.compare($0, frame).changed } ?? false
            change = now
            last = frame
            polls += 1
            if persisted && still { break }
        }
        let each = "\(capturing / max(polls, 1))"
        Self.log.info("verified: \(polls) captures from the \(source, privacy: .public), \(each, privacy: .public) each")
        let settled = still && (persisted || !change.changed)
        var verified: [String: JSONValue] = [
            "status": change.changed ? "changed" : "unchanged", "changeRatio": .double((change.ratio * 10000).rounded() / 10000),
            "tiles": .int(Int64(change.tiles)),
            "settled": .bool(settled), "waitedMs": waited(),
        ]
        if let box = change.box {
            verified["bbox"] = [
                "x": .int(Int64(box.x)), "y": .int(Int64(box.y)), "width": .int(Int64(box.width)), "height": .int(Int64(box.height)),
            ]
        }
        if !change.changed { verified["reason"] = settled ? "no_pixel_change" : "timeout_unsettled" }
        return screen(of: last ?? before, ["verified": .object(verified)])
    }

    /// `reply` with the screen's size in guest pixels.
    private func screen(of frame: GrayFrame, _ reply: [String: JSONValue]) -> [String: JSONValue] {
        var reply = reply
        reply["screen"] = [
            "width": .int(Int64((Double(frame.width) * frame.scale).rounded())),
            "height": .int(Int64((Double(frame.height) * frame.scale).rounded())),
        ]
        return reply
    }
}

extension JSONValue {
    /// This object with `key` set.
    fileprivate func adding(_ key: String, _ value: JSONValue) -> JSONValue {
        guard case .object(var fields) = self else { return self }
        fields[key] = value
        return .object(fields)
    }
}
