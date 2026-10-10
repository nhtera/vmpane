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
    let kind = BackendKind.vz
    let capabilities: LiveCapabilities = [.pause, .suspend, .liveSnapshot, .screenshot, .input]
    let events: AsyncStream<BackendEvent>
    private let continuation: AsyncStream<BackendEvent>.Continuation
    private let lock = NSLock()
    private var calls: [String] = []
    private var failures: Set<String> = []
    /// Graceful stops are ignored (a guest that does not shut down), forcing the force path.
    var ignoresGracefulStop = false
    /// Live settings this backend applies (`applyLive`); the config of the last start.
    var livePaths: Set<String> = []
    private(set) var lastStartConfig: VMConfigV1?

    init() {
        (events, continuation) = AsyncStream.makeStream(of: BackendEvent.self)
    }

    var recordedCalls: [String] { lock.withLock { calls } }
    func failOnce(_ call: String) { lock.withLock { _ = failures.insert(call) } }

    private func record(_ call: String) throws {
        try lock.withLock {
            calls.append(call)
            if failures.remove(call) != nil { throw POSIXError(.EIO) }
        }
    }

    func start(_ options: StartOptions) async throws {
        try record(options.stateDirectory == nil ? "start" : "start.resume")
        lock.withLock { lastStartConfig = options.config }
        continuation.yield(.started)
    }
    func pause() async throws { try record("pause"); continuation.yield(.paused) }
    func resume() async throws { try record("resume"); continuation.yield(.resumed) }
    func suspend(to stateDirectory: URL) async throws {
        try record("suspend")
        try Data("ram".utf8).write(to: stateDirectory.appendingPathComponent("suspend.scripted"))
    }
    func saveState(to stateDirectory: URL) async throws {
        try record("saveState")
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
    func send(_ input: InputEvent) async throws { lock.withLock { calls.append("input.\(input)") } }
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
