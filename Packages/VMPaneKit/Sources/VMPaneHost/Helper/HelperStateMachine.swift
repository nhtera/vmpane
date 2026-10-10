import VMPaneCore

/// The helper's VM lifecycle as a pure transition function.
///
/// ```
/// stopped → starting → running ⇄ paused
/// running|paused → suspending → stopped (state saved)
/// running|paused → stopping → stopped
/// any → error;  error → starting | stopped
/// ```
public enum HelperStateMachine {
    public enum Event: String, Sendable, CaseIterable {
        // Requests (from control clients).
        case start, pause, resume, suspend, stop
        // Backend reports.
        case started, paused, resumed, suspended, stopped, failed
    }

    public struct InvalidTransition: Error, Equatable, Sendable {
        public let state: VMRunState
        public let event: Event
    }

    public static func transition(_ state: VMRunState, _ event: Event) -> Result<VMRunState, InvalidTransition> {
        if event == .failed { return .success(.error) }
        let next: VMRunState? =
            switch (state, event) {
            case (.stopped, .start), (.error, .start): .starting
            case (.starting, .started): .running
            case (.running, .pause): .paused
            case (.paused, .resume): .running
            // Some backends report pause/resume themselves (e.g. the guest or a debugger paused it).
            case (.running, .paused): .paused
            case (.paused, .resumed): .running
            case (.running, .suspend), (.paused, .suspend): .suspending
            case (.suspending, .suspended): .stopped
            case (.running, .stop), (.paused, .stop), (.starting, .stop): .stopping
            case (.error, .stop): .stopped
            // The guest can power off by itself in any running state.
            case (.stopping, .stopped), (.running, .stopped), (.paused, .stopped), (.starting, .stopped),
                (.suspending, .stopped):
                .stopped
            default: nil
            }
        guard let next else { return .failure(InvalidTransition(state: state, event: event)) }
        return .success(next)
    }

    /// Requests allowed in `state` (for UI enablement and `vm.info`).
    public static func allowedRequests(in state: VMRunState) -> [Event] {
        [Event.start, .pause, .resume, .suspend, .stop].filter {
            if case .success = transition(state, $0) { return true }
            return false
        }
    }
}
