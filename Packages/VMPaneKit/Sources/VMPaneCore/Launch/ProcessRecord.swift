import Darwin
import Foundation

/// A process identified by pid + start time (microseconds). Pids are reused; a pid with the same start
/// time is the same process. The executable path is recorded too and, when it can still be read, must
/// match as well (it cannot be read once the binary was deleted, e.g. a garbage-collected runtime copy).
public struct ProcessRecord: Codable, Equatable, Hashable, Sendable {
    public var pid: Int32
    /// Start time in microseconds since 1970 (from the kernel's process table).
    public var startTime: UInt64
    public var executablePath: String

    public init(pid: Int32, startTime: UInt64, executablePath: String) {
        self.pid = pid
        self.startTime = startTime
        self.executablePath = executablePath
    }

    /// The live process with this pid, or nil if there is none (or only a zombie). `executablePath` is
    /// empty when the kernel cannot report it (deleted binary).
    public static func current(pid: Int32) -> ProcessRecord? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, info.pbi_status != UInt32(SZOMB) else { return nil }
        var path = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &path, UInt32(path.count))
        let start = UInt64(info.pbi_start_tvsec) * 1_000_000 + UInt64(info.pbi_start_tvusec)
        let executable = length > 0 ? (String(bytes: path.prefix(Int(length)), encoding: .utf8) ?? "") : ""
        return ProcessRecord(pid: pid, startTime: start, executablePath: executable)
    }

    public static var this: ProcessRecord {
        guard let record = current(pid: getpid()) else { fatalError("cannot read own process info") }
        return record
    }

    /// Whether `other` (a live reading) is this recorded process.
    public func matches(_ other: ProcessRecord) -> Bool {
        guard pid == other.pid, startTime == other.startTime else { return false }
        return executablePath.isEmpty || other.executablePath.isEmpty || executablePath == other.executablePath
    }

    /// Whether this exact process is still running.
    public var isAlive: Bool { Self.current(pid: pid).map(matches) ?? false }

    /// Stops this process if (and only if) it is still the recorded one: SIGTERM, up to `grace` seconds,
    /// then SIGKILL, and waits until it is gone. Returns false only if it survived SIGKILL for 5 s.
    @discardableResult
    public func terminate(grace: TimeInterval = 5) -> Bool {
        guard isAlive else { return true }
        kill(pid, SIGTERM)
        if waitForExit(timeout: grace) { return true }
        guard isAlive else { return true }
        kill(pid, SIGKILL)
        return waitForExit(timeout: 5)
    }

    private func waitForExit(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            var status: Int32 = 0
            _ = waitpid(pid, &status, WNOHANG)  // reaps it if it is our own child; harmless otherwise
            if !isAlive { return true }
            usleep(20_000)
        } while Date() < deadline
        return !isAlive
    }
}
