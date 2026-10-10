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
    .suspending: [.suspended: .stopped, .stopped: .stopped],
    .stopping: [.stopped: .stopped],
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
    let capabilities: LiveCapabilities = [.pause, .suspend, .screenshot, .input]
    let events: AsyncStream<BackendEvent>
    private let continuation: AsyncStream<BackendEvent>.Continuation
    private let lock = NSLock()
    private var calls: [String] = []
    var failNext: String?

    init() {
        (events, continuation) = AsyncStream.makeStream(of: BackendEvent.self)
    }

    var recordedCalls: [String] { lock.withLock { calls } }

    private func record(_ call: String, then event: BackendEvent) throws {
        try lock.withLock {
            calls.append(call)
            if failNext == call {
                failNext = nil
                throw POSIXError(.EIO)
            }
        }
        continuation.yield(event)
    }

    func start(_ options: StartOptions) async throws { try record("start", then: .started) }
    func pause() async throws { try record("pause", then: .paused) }
    func resume() async throws { try record("resume", then: .resumed) }
    func suspend(to stateDirectory: URL) async throws { try record("suspend", then: .suspended) }
    func stop(_ mode: StopMode) async throws { try record("stop.\(mode.rawValue)", then: .stopped(reason: "requested")) }
    func screenshot(maxEdge: Int) async throws -> Data { Data([0x89, 0x50, 0x4E, 0x47]) }
    func send(_ input: InputEvent) async throws { lock.withLock { calls.append("input") } }

    /// Simulates the guest powering off by itself.
    func guestPowersOff() { continuation.yield(.stopped(reason: "guest")) }
}

@Test func scriptedBackendDrivesTheStateMachine() async throws {
    let backend = ScriptedBackend()
    var state = VMRunState.stopped
    var iterator = backend.events.makeAsyncIterator()
    try await backend.start(StartOptions(headless: true))
    state = try HelperStateMachine.transition(state, .start).get()
    if case .started? = await iterator.next() { state = try HelperStateMachine.transition(state, .started).get() }
    #expect(state == .running)
    backend.guestPowersOff()
    if case .stopped? = await iterator.next() { state = try HelperStateMachine.transition(state, .stopped).get() }
    #expect(state == .stopped)
    #expect(backend.recordedCalls == ["start"])
}
