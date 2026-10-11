// The integration tests' way into a helper's control socket: relays stdin to the socket and the socket to stdout.
// scripts/itest.sh builds it ad hoc signed as app.vmpane.mac.itest, an identity a development (ad hoc) helper
// treats as the app and a release helper never does (PeerClassifier). Never shipped.
// Usage: vmpane-itest-bridge <socket>
import Darwin
import Foundation

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: vmpane-itest-bridge <socket>\n".utf8))
    exit(64)
}
let path = CommandLine.arguments[1]
let fd = socket(AF_UNIX, SOCK_STREAM, 0)
var address = sockaddr_un()
address.sun_family = sa_family_t(AF_UNIX)
withUnsafeMutableBytes(of: &address.sun_path) { buffer in
    let bytes = Array(path.utf8.prefix(buffer.count - 1))
    buffer.copyBytes(from: bytes + [0])
}
let connected = withUnsafePointer(to: &address) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
}
guard connected == 0 else {
    FileHandle.standardError.write(Data("vmpane-itest-bridge: cannot connect to \(path): \(String(cString: strerror(errno)))\n".utf8))
    exit(69)
}
var enabled: Int32 = 1
setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))

/// Copies `from` to `to` until end-of-file; false on an error.
func copy(_ from: Int32, _ to: Int32) {
    var buffer = [UInt8](repeating: 0, count: 64 << 10)
    while true {
        let count = read(from, &buffer, buffer.count)
        if count < 0, errno == EINTR { continue }
        guard count > 0 else { return }
        var sent = 0
        while sent < count {
            let wrote = buffer.withUnsafeBytes { write(to, $0.baseAddress.map { $0 + sent }, count - sent) }
            if wrote < 0, errno == EINTR { continue }
            guard wrote > 0 else { return }
            sent += wrote
        }
    }
}

let input = Thread {
    copy(STDIN_FILENO, fd)
    shutdown(fd, SHUT_WR)  // our client is done sending; answers may still come
}
input.start()
copy(fd, STDOUT_FILENO)
exit(0)
