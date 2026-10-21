import Foundation
import Testing
import VMPaneCore

@testable import VMPaneHost

private typealias Event = HelperStateMachine.Event

/// Every allowed (state, event) pair besides `failed`, which always leads to `error`.
private let allowed: [VMRunState: [Event: VMRunState]] = [
    .stopped: [.start: .starting],
    .starting: [.started: .running, .stop: .stopping, .stopped: .stopped],
    .running: [.pause: .paused, .paused: .paused, .suspend: .suspending, .stop: .stopping, .stopped: .stopped],
    .paused: [.resume: .running, .resumed: .running, .suspend: .suspending, .stop: .stopping, .stopped: .stopped],
    .suspending: [.suspended: .stopped, .stopped: .stopped, .resumed: .running],
    .stopping: [.stopped: .stopped, .stop: .stopping],
    .error: [.start: .starting, .stop: .stopped],
]

@Test(arguments: VMRunState.allCases)
func transitionTableIsExhaustive(state: VMRunState) {
    for event in Event.allCases {
        let result = HelperStateMachine.transition(state, event)
        if event == .failed {
            #expect(result == .success(.error))
        } else if let next = allowed[state]?[event] {
            #expect(result == .success(next), "\(state) + \(event)")
        } else {
            #expect(result == .failure(.init(state: state, event: event)), "\(state) + \(event) should be invalid")
        }
    }
}

@Test func allowedRequestsFollowTheTable() {
    #expect(HelperStateMachine.allowedRequests(in: .stopped) == [.start])
    #expect(HelperStateMachine.allowedRequests(in: .running) == [.pause, .suspend, .stop])
    #expect(HelperStateMachine.allowedRequests(in: .paused) == [.resume, .suspend, .stop])
    #expect(HelperStateMachine.allowedRequests(in: .suspending).isEmpty)
}

/// A backend that follows a script, for helper tests without a hypervisor.
final class ScriptedBackend: VMBackend, @unchecked Sendable {
    let kind: BackendKind
    let capabilities: LiveCapabilities = [.pause, .suspend, .liveSnapshot, .screenshot, .input]
    let events: AsyncStream<BackendEvent>
    private let continuation: AsyncStream<BackendEvent>.Continuation
    let agentSockets: AsyncStream<Int32>
    private let agentContinuation: AsyncStream<Int32>.Continuation
    private let lock = NSLock()
    private var calls: [String] = []
    private var failures: [String: any Error] = [:]
    /// Graceful stops are ignored (a guest that does not shut down), forcing the force path.
    var ignoresGracefulStop = false
    /// Live settings this backend applies (`applyLive`); the config of the last start.
    var livePaths: Set<String> = []
    private(set) var lastStartConfig: VMConfigV1?
    /// How long a start takes before the VM runs (a macOS install takes minutes); nil: at once.
    var startDelay: Duration?

    init(kind: BackendKind = .vz) {
        self.kind = kind
        (events, continuation) = AsyncStream.makeStream(of: BackendEvent.self)
        (agentSockets, agentContinuation) = AsyncStream.makeStream(of: Int32.self)
    }

    /// Hands the helper a guest agent connection, as VZ's vsock listener does.
    func connectAgent(_ fd: Int32) { agentContinuation.yield(fd) }

    var recordedCalls: [String] { lock.withLock { calls } }
    func failOnce(_ call: String, with error: any Error = POSIXError(.EIO)) { lock.withLock { failures[call] = error } }

    private func record(_ call: String) throws {
        try lock.withLock {
            calls.append(call)
            if let error = failures.removeValue(forKey: call) { throw error }
        }
    }

    func start(_ options: StartOptions) async throws {
        try record(options.stateDirectory == nil ? "start" : "start.resume")
        lock.withLock { lastStartConfig = options.config }
        if let startDelay { try await Task.sleep(for: startDelay) }
        continuation.yield(.started)
    }
    func pause() async throws { try record("pause"); continuation.yield(.paused) }
    func resume() async throws { try record("resume"); continuation.yield(.resumed) }
    /// Like VZ: the VM's power-off at the end of a suspend arrives as a stop, before `suspend` returns.
    var announcesStopOnSuspend = false
    func suspend(to stateDirectory: URL) async throws {
        try record("suspend")
        try Data("ram".utf8).write(to: stateDirectory.appendingPathComponent("suspend.scripted"))
        if announcesStopOnSuspend {
            continuation.yield(.stopped(reason: "powered off"))
            try? await Task.sleep(for: .milliseconds(100))  // the helper applies it meanwhile
        }
    }
    /// How long a live snapshot's save takes. Like VZ, a save while one runs fails.
    var saveDelay: Duration?
    private var saving = false
    func saveState(to stateDirectory: URL) async throws {
        try record("saveState")
        guard !lock.withLock({ saving }) else { throw POSIXError(.EBUSY) }
        lock.withLock { saving = true }
        defer { lock.withLock { saving = false } }
        if let saveDelay { try await Task.sleep(for: saveDelay) }
        try Data("ram".utf8).write(to: stateDirectory.appendingPathComponent("suspend.scripted"))
    }
    func stop(_ mode: StopMode) async throws {
        try record("stop.\(mode.rawValue)")
        if mode == .graceful && ignoresGracefulStop { return }
        continuation.yield(.stopped(reason: "requested"))
    }
    func screenshot(maxEdge: Int) async throws -> Screenshot {
        Screenshot(png: Data([0x89, 0x50, 0x4E, 0x47]), width: 4, height: 3)
    }
    /// How long each typed character takes (`typingPace`); text is recorded once typed.
    var typingDelay = Duration.milliseconds(1)
    /// When each input arrived.
    private(set) var inputTimes: [ContinuousClock.Instant] = []
    /// What `grayFrame` returns, one per call (the last one stays); none: no display.
    var frames: [GrayFrame] = []
    /// The next input fails (once).
    var failNextInput = false
    func send(_ input: InputEvent) async throws {
        if case .text(let text) = input { try await Task.sleep(for: typingDelay * text.count) }
        try lock.withLock {
            if failNextInput {
                failNextInput = false
                throw POSIXError(.EIO)
            }
            calls.append("input.\(input)")
            inputTimes.append(.now)
        }
    }
    var typingPace: Duration { typingDelay }
    func grayFrame() async -> GrayFrame? {
        lock.withLock { frames.count > 1 ? frames.removeFirst() : frames.first }
    }
    func ejectMedia(_ id: String) async throws { try record("eject.\(id)") }
    func applyLive(_ config: VMConfigV1, paths: [String]) async -> Set<String> {
        lock.withLock {
            calls.append("applyLive.\(paths.joined(separator: ","))")
            return livePaths.intersection(paths)
        }
    }

    /// Simulates the guest powering off by itself, or any other event.
    func emit(_ event: BackendEvent) { continuation.yield(event) }
}

@Test func scriptedBackendDrivesTheStateMachine() async throws {
    let backend = ScriptedBackend()
    var state = VMRunState.stopped
    var iterator = backend.events.makeAsyncIterator()
    try await backend.start(StartOptions(headless: true))
    state = try HelperStateMachine.transition(state, .start).get()
    if case .started? = await iterator.next() { state = try HelperStateMachine.transition(state, .started).get() }
    #expect(state == .running)
    backend.emit(.stopped(reason: "guest"))
    if case .stopped? = await iterator.next() { state = try HelperStateMachine.transition(state, .stopped).get() }
    #expect(state == .stopped)
    #expect(backend.recordedCalls == ["start"])
}
