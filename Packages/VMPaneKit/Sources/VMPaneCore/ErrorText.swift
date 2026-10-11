import Foundation

/// Errors as people read them.
public enum ErrorText {
    /// A system error (Virtualization, Cocoa, POSIX…) as its description and reason, not its domain, code and user
    /// info; a Swift error as its own text.
    public static func readable(_ error: Error) -> String {
        guard Swift.type(of: error) is NSError.Type else { return String(describing: error) }
        let error = error as NSError
        let description = error.localizedDescription
        guard let reason = error.localizedFailureReason, !description.contains(reason) else { return description }
        return "\(description) \(reason)"
    }
}
