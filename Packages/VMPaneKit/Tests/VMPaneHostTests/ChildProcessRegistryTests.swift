import Foundation
import Testing
import VMPaneCore

@testable import VMPaneHost

@Test func registryRecordsRemovesAndTerminatesChildren() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("vp-reg-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let run = RunFiles(paths: VMPanePaths(root: root), sid: ShortID(UUID()))
    let registry = ChildProcessRegistry(runFiles: run)
    let sleep = URL(fileURLWithPath: "/bin/sleep")
    let first = try registry.spawn(sleep, .init(arguments: ["300"]))
    let second = try registry.spawn(sleep, .init(arguments: ["300"]))
    #expect(run.readChildren() == [first, second])

    first.terminate()
    try registry.remove(first)
    #expect(registry.current == [second])
    #expect(run.readChildren() == [second])

    registry.terminateAll()
    #expect(!second.isAlive)
    #expect(registry.current.isEmpty)
    #expect(run.readChildren().isEmpty)
}

@Test func childOutputGoesToTheLogFile() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("vp-log-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let log = root.appendingPathComponent("child.log")
    let child = try ChildSpawner.spawn(
        URL(fileURLWithPath: "/bin/sh"),
        .init(arguments: ["-c", "echo out; echo err >&2; sleep 5"], logFile: log))
    defer { child.terminate() }
    var text = ""
    for _ in 0..<200 where !(text.contains("out") && text.contains("err")) {
        usleep(10_000)
        text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
    }
    #expect(text.contains("out") && text.contains("err"))
}

/// A launcher that execs into another program (sandbox-exec → QEMU) is recorded by pid + start time, so it is
/// still recognised (and reaped) after its executable path changed.
@Test func launcherThatExecsStaysRecognisable() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("vp-exec-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let run = RunFiles(paths: VMPanePaths(root: root), sid: ShortID(UUID()))
    let registry = ChildProcessRegistry(runFiles: run)
    let child = try registry.spawn(
        URL(fileURLWithPath: "/bin/sh"), .init(arguments: ["-c", "exec /bin/sleep 300"], recordsExecutable: false))
    for _ in 0..<200 where ProcessRecord.current(pid: child.pid)?.executablePath != "/bin/sleep" { usleep(10_000) }
    #expect(ProcessRecord.current(pid: child.pid)?.executablePath == "/bin/sleep")
    #expect(child.executablePath.isEmpty && child.isAlive)
    #expect(run.reapChildren(of: .this).isEmpty)
    #expect(!child.isAlive)
}
