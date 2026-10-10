import Darwin
import Foundation

/// How a child process ended.
public enum ChildExit: Equatable, Sendable, CustomStringConvertible {
    case exited(Int32)
    case signaled(Int32)

    init(status: Int32) {
        let signal = status & 0x7F
        self = signal == 0 ? .exited((status >> 8) & 0xFF) : .signaled(signal)
    }

    public var description: String {
        switch self {
        case .exited(let code): "exited with status \(code)"
        case .signaled(let signal): "killed by signal \(signal) (\(String(cString: strsignal(signal))))"
        }
    }
}

/// Reports when one of this process's children exits, and reaps it (no zombie is left behind).
public final class ChildExitWatcher: @unchecked Sendable {
    private let source: DispatchSourceProcess
    private let lock = NSLock()
    private var result: ChildExit?
    private var waiters: [CheckedContinuation<ChildExit, Never>] = []

    /// `pid` must be a child of this process (spawned by it).
    public init(pid: pid_t, queue: DispatchQueue = .global()) {
        source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        source.setEventHandler { [weak self] in self?.reap(pid) }
        source.resume()
        // An exit before the source was armed raises no event: check once.
        queue.async { [weak self] in self?.reap(pid, onlyIfExited: true) }
    }

    deinit { source.cancel() }

    /// Waits until the child has exited.
    public func wait() async -> ChildExit {
        await withCheckedContinuation { continuation in
            lock.withLock {
                if let result { continuation.resume(returning: result) } else { waiters.append(continuation) }
            }
        }
    }

    /// The exit, if it happened already.
    public var exit: ChildExit? { lock.withLock { result } }

    private func reap(_ pid: pid_t, onlyIfExited: Bool = false) {
        var status: Int32 = 0
        var reaped: pid_t
        repeat { reaped = waitpid(pid, &status, onlyIfExited ? WNOHANG : 0) } while reaped == -1 && errno == EINTR
        // -1/ECHILD: someone else reaped it (e.g. ProcessRecord.terminate); the status is then unknown.
        let exit: ChildExit
        if reaped == pid {
            exit = ChildExit(status: status)
        } else if reaped == -1 {
            exit = .exited(-1)
        } else {
            return  // still running
        }
        let resumed: [CheckedContinuation<ChildExit, Never>] = lock.withLock {
            guard result == nil else { return [] }
            result = exit
            defer { waiters.removeAll() }
            return waiters
        }
        for waiter in resumed { waiter.resume(returning: exit) }
        source.cancel()
    }
}
