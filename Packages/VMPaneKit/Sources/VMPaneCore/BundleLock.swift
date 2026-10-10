import Darwin
import Foundation

/// Exclusive `flock` on a lock file (`bundle.lock`, `library.lock`). Whoever holds a bundle's lock is the
/// only writer of its disks and config.
///
/// The descriptor is close-on-exec. Child processes that write the disks (QEMU, swtpm) get it explicitly
/// through `ChildSpawner` (`inheriting:`), so the lock lasts as long as any writer is alive, even if the
/// helper dies first, while unrelated subprocesses (`open`, `hdiutil`, …) never pin it.
public final class FileLock: @unchecked Sendable {
    public let url: URL
    /// The open, locked descriptor. Valid until `release()` or deinit.
    public let fileDescriptor: Int32
    private let state = NSLock()
    private var released = false

    private init(url: URL, fileDescriptor: Int32) {
        self.url = url
        self.fileDescriptor = fileDescriptor
    }

    /// Takes the lock without waiting. Returns nil when another open file description holds it.
    public static func tryAcquire(_ url: URL) throws -> FileLock? {
        let fd = open(url.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError.current() }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            let error = errno
            close(fd)
            if error == EWOULDBLOCK { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO)
        }
        return FileLock(url: url, fileDescriptor: fd)
    }

    /// Waits for the lock (short critical sections only, e.g. the library index).
    public static func acquire(_ url: URL) throws -> FileLock {
        let fd = open(url.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError.current() }
        while flock(fd, LOCK_EX) != 0 {
            if errno == EINTR { continue }
            let error = POSIXError.current()
            close(fd)
            throw error
        }
        return FileLock(url: url, fileDescriptor: fd)
    }

    public func release() {
        state.lock()
        defer { state.unlock() }
        guard !released else { return }
        released = true
        close(fileDescriptor)
    }

    deinit { release() }
}
