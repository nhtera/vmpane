import CoreGraphics
import Foundation

/// Whether this login session's screen is locked. Virtualization encrypts saved VM memory with a
/// Secure Enclave key that is unusable while the Mac is locked, so restores fail then (saving still works).
public enum SessionLock {
    public static func isLocked() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return session["CGSSessionScreenIsLocked"] as? Bool ?? false
    }
}
