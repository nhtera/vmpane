import Darwin
import Foundation

/// Starts child processes with only the descriptors they should have: stdin/stdout/stderr plus an
/// explicit list (e.g. the bundle lock for disk writers). Everything else is closed at exec
/// (`POSIX_SPAWN_CLOEXEC_DEFAULT`), so no child accidentally holds a lock or a socket.
public enum ChildSpawner {
    public struct Options: Sendable {
        public var arguments: [String]
        public var environment: [String: String]?
        /// Descriptors the child keeps, at the same numbers.
        public var inheriting: [Int32]
        /// Where stdout and stderr go (`/dev/null` when nil).
        public var logFile: URL?
        /// False for a launcher that replaces itself with another program (`sandbox-exec`): its executable
        /// path changes after start, so the record identifies it by pid and start time alone (exec keeps both).
        public var recordsExecutable: Bool
        /// The child's working directory (the helper's when nil).
        public var workingDirectory: URL?

        public init(
            arguments: [String] = [], environment: [String: String]? = nil, inheriting: [Int32] = [], logFile: URL? = nil,
            recordsExecutable: Bool = true, workingDirectory: URL? = nil
        ) {
            self.arguments = arguments
            self.environment = environment
            self.inheriting = inheriting
            self.logFile = logFile
            self.recordsExecutable = recordsExecutable
            self.workingDirectory = workingDirectory
        }
    }

    /// Spawns `executable`, running, and returns its record.
    public static func spawn(_ executable: URL, _ options: Options = Options()) throws -> ProcessRecord {
        let child = try spawnSuspended(executable, options)
        resume(child)
        return child
    }

    /// Spawns `executable` stopped before its first instruction, so it can be recorded durably first
    /// (a crash then never leaves an unrecorded child holding the bundle lock). Follow with `resume` or
    /// `discard`.
    public static func spawnSuspended(_ executable: URL, _ options: Options = Options()) throws -> ProcessRecord {
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Ignored signals survive exec, and the helper ignores SIGTERM (it handles it via a dispatch
        // source): reset every signal to its default and clear the mask, so children stop on SIGTERM.
        var allSignals = sigset_t()
        sigfillset(&allSignals)
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        posix_spawnattr_setsigdefault(&attributes, &allSignals)
        posix_spawnattr_setsigmask(&attributes, &noSignals)
        posix_spawnattr_setflags(
            &attributes,
            Int16(
                POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
                    | POSIX_SPAWN_START_SUSPENDED))

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        let output = options.logFile?.path ?? "/dev/null"
        posix_spawn_file_actions_addopen(&actions, 1, output, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        posix_spawn_file_actions_adddup2(&actions, 1, 2)
        for fd in options.inheriting { posix_spawn_file_actions_addinherit_np(&actions, fd) }
        if let directory = options.workingDirectory { posix_spawn_file_actions_addchdir_np(&actions, directory.path) }

        let argv: [UnsafeMutablePointer<CChar>?] = ([executable.path] + options.arguments).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        let environment = options.environment ?? ProcessInfo.processInfo.environment
        let envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { envp.forEach { free($0) } }

        var pid: pid_t = 0
        let result = posix_spawn(&pid, executable.path, &actions, &attributes, argv, envp)
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EIO) }
        guard var record = ProcessRecord.current(pid: pid) else {
            kill(pid, SIGKILL)
            var status: Int32 = 0
            waitpid(pid, &status, 0)
            throw POSIXError(.ESRCH)
        }
        if !options.recordsExecutable { record.executablePath = "" }
        return record
    }

    public static func resume(_ child: ProcessRecord) {
        if child.isAlive { kill(child.pid, SIGCONT) }
    }

    /// Kills a child that could not be recorded and reaps it.
    public static func discard(_ child: ProcessRecord) {
        guard child.isAlive else { return }
        kill(child.pid, SIGKILL)
        var status: Int32 = 0
        waitpid(child.pid, &status, 0)
    }
}
