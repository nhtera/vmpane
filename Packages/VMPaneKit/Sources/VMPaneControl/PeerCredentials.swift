import Darwin
import Foundation

/// Who is on the other end of an accepted control connection, as reported by the kernel.
public struct PeerCredentials: Sendable, Equatable {
    public let uid: uid_t
    public let pid: pid_t
    /// `audit_token_t` bytes, for code-signing checks (`PeerIdentity`); immune to pid reuse.
    public let auditToken: Data

    /// Reads `LOCAL_PEERCRED`, `LOCAL_PEERPID` and `LOCAL_PEERTOKEN` of a connected socket.
    public static func of(socket fd: Int32) throws -> PeerCredentials {
        var cred = xucred()
        var length = socklen_t(MemoryLayout<xucred>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERCRED, &cred, &length) == 0 else { throw POSIXError.current() }
        var pid: pid_t = 0
        length = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0 else { throw POSIXError.current() }
        var token = audit_token_t()
        length = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &length) == 0 else { throw POSIXError.current() }
        return PeerCredentials(uid: cred.cr_uid, pid: pid, auditToken: withUnsafeBytes(of: token) { Data($0) })
    }
}
