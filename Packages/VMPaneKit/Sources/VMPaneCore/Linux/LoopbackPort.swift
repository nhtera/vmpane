import Foundation

/// A TCP port for a VM's SSH forward on 127.0.0.1: free now, and outside the range macOS gives outgoing connections
/// (49152-65535), so it does not collide with one later.
public enum LoopbackPort {
    public static let range = 20022...29999

    public static func free(avoiding taken: Set<Int> = []) -> Int? {
        for _ in 0..<64 {
            let port = Int.random(in: range)
            if !taken.contains(port), isFree(port) { return port }
        }
        return nil
    }

    static func isFree(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
        }
    }
}
