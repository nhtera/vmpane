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

/// The cancel is what ends the process (a signal, not its own end) and the wait returns well before `sleep 30`
/// would: the Mac that runs the suite under ASan is shared, and the signal's round trip took 7 s there once
/// (2026-11-09).
@Test func aCancelEndsARunningProcess() async throws {
    let process = sleeper()
    let run = Task { try await CancellableProcess.run(process) }
    for _ in 0..<500 where !process.isRunning { try await Task.sleep(for: .milliseconds(20)) }
    try #require(process.isRunning, "started within 10 s")
    let cancelled = ContinuousClock.now
    run.cancel()
    _ = try? await run.value
    #expect(!process.isRunning)
    #expect(process.terminationReason == .uncaughtSignal, "ended by the terminate, not on its own")
    #expect(ContinuousClock.now - cancelled < .seconds(15))
}
