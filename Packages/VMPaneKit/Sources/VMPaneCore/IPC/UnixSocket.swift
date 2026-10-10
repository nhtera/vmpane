import Darwin
import Foundation

/// Low-level AF_UNIX stream socket helpers (control sockets, QMP, guest agent ports).
package enum UnixSocket {
    /// A new stream socket: close-on-exec, no SIGPIPE on writes to a closed peer.
    package static func make() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError.current() }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var enabled: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
        return fd
    }

    /// Runs `body` with a `sockaddr_un` for `path` (relative or absolute, at most 103 bytes).
    package static func withAddress<T>(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> T) throws -> T {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < capacity else { throw POSIXError(.ENAMETOOLONG) }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return try withUnsafePointer(to: &address) { pointer in
            try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { try body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
    }

    /// `bind`, or a relative bind from inside the directory when the absolute path is too long for `sun_path`.
    package static func bind(_ fd: Int32, to address: UnixSocketAddress) throws {
        switch address {
        case .absolute(let path):
            try withAddress(path) { pointer, length in
                guard Darwin.bind(fd, pointer, length) == 0 else { throw POSIXError.current() }
            }
        case .relative(let directory, let name):
            try insideDirectory(directory) {
                try withAddress(name) { pointer, length in
                    guard Darwin.bind(fd, pointer, length) == 0 else { throw POSIXError.current() }
                }
            }
        }
    }

    package static func connect(_ fd: Int32, to address: UnixSocketAddress) throws {
        switch address {
        case .absolute(let path):
            try withAddress(path) { pointer, length in
                guard Darwin.connect(fd, pointer, length) == 0 else { throw POSIXError.current() }
            }
        case .relative(let directory, let name):
            try insideDirectory(directory) {
                try withAddress(name) { pointer, length in
                    guard Darwin.connect(fd, pointer, length) == 0 else { throw POSIXError.current() }
                }
            }
        }
    }

    private static let workingDirectoryLock = NSLock()

    /// Runs `body` with the working directory set to `path`, then restores it. The working directory is
    /// process-wide (`bindat`/`connectat` and per-thread `chdir` are not public API), so this is serialised
    /// and only used for over-long socket paths; VMPane code never relies on relative paths.
    private static func insideDirectory<T>(_ path: String, _ body: () throws -> T) throws -> T {
        workingDirectoryLock.lock()
        defer { workingDirectoryLock.unlock() }
        let saved = open(".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard saved >= 0 else { throw POSIXError.current() }
        defer {
            _ = fchdir(saved)
            close(saved)
        }
        guard chdir(path) == 0 else { throw POSIXError.current() }
        return try body()
    }

    /// Writes all of `data` (blocking socket).
    package static func writeAll(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let written = write(fd, base + offset, buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw POSIXError.current()
                }
                offset += written
            }
        }
    }
}
