import Foundation
import Testing

@testable import VMPaneHost

private func sleeper() -> Process {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sleep")
    process.arguments = ["30"]
    return process
}

/// Cancel during "Verifying" reaches the conversion before qemu-img starts: it must not start (terminating a process
/// that never ran raises an exception).
@Test func aCancelBeforeTheStartKeepsTheProcessFromStarting() async throws {
    let process = sleeper()
    let run = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await CancellableProcess.run(process)
    }
    await #expect(throws: CancellationError.self) { try await run.value }
    #expect(!process.isRunning)
}

@Test func aCancelEndsARunningProcess() async throws {
    let process = sleeper()
    let run = Task { try await CancellableProcess.run(process) }
    for _ in 0..<50 where !process.isRunning { try await Task.sleep(for: .milliseconds(20)) }
    let cancelled = ContinuousClock.now
    run.cancel()
    _ = try? await run.value
    #expect(!process.isRunning && ContinuousClock.now - cancelled < .seconds(2))
}
