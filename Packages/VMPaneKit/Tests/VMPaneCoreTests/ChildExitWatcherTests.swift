import Darwin
import Foundation
import Testing

@testable import VMPaneCore

@Test func watcherReportsExitStatusAndSignal() async throws {
    let exits = try ChildSpawner.spawn(URL(fileURLWithPath: "/bin/sh"), .init(arguments: ["-c", "exit 3"]))
    #expect(await ChildExitWatcher(pid: exits.pid).wait() == .exited(3))

    let sleeper = try ChildSpawner.spawn(URL(fileURLWithPath: "/bin/sleep"), .init(arguments: ["30"]))
    let watcher = ChildExitWatcher(pid: sleeper.pid)
    #expect(watcher.exit == nil)
    kill(sleeper.pid, SIGTERM)
    #expect(await watcher.wait() == .signaled(SIGTERM))
    #expect(watcher.exit == .signaled(SIGTERM))
    #expect(!sleeper.isAlive)
}

@Test func watcherCreatedAfterTheExitStillReportsIt() async throws {
    let quick = try ChildSpawner.spawn(URL(fileURLWithPath: "/usr/bin/true"))
    try await Task.sleep(for: .milliseconds(300))
    #expect(await ChildExitWatcher(pid: quick.pid).wait() == .exited(0))
}
