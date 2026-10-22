import Foundation
import os

/// Runs a prepared `Process` to its end; a cancelled task ends it. A cancel that comes before the process started
/// keeps it from starting (`Process.terminate()` on a process that never ran raises an exception).
enum CancellableProcess {
    static func run(_ process: Process) async throws -> Int32 {
        let state = OSAllocatedUnfairLock(initialState: (cancelled: false, started: false))
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (done: CheckedContinuation<Int32, Error>) in
                process.terminationHandler = { done.resume(returning: $0.terminationStatus) }
                let failure: Error? = state.withLock { state in
                    guard !state.cancelled else { return CancellationError() }
                    do {
                        try process.run()
                        state.started = true
                        return nil
                    } catch {
                        return error
                    }
                }
                if let failure {
                    process.terminationHandler = nil
                    done.resume(throwing: failure)
                }
            }
        } onCancel: {
            state.withLock { state in
                state.cancelled = true
                if state.started, process.isRunning { process.terminate() }
            }
        }
    }
}
