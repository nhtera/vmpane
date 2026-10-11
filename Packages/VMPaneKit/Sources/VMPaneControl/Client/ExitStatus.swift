import Foundation

/// `vmpane` exit codes (sysexits where one fits). `vmpane exec` exits with the guest command's own code instead.
public enum ExitStatus: Int32, Sendable, CaseIterable {
    case ok = 0
    case failure = 1
    /// Bad arguments.
    case usage = 64
    /// No VM matches the selector (or several do).
    case notFound = 66
    /// The VM's helper or guest agent cannot be reached, or the backend is missing.
    case unavailable = 69
    /// Busy or in the wrong state for this; trying again later may work.
    case tempFail = 75
    /// The VM's policy (or the kill switch) does not allow this client to do it.
    case policyDenied = 77

    /// The exit code for a control-protocol error.
    public static func of(_ error: RPCError) -> ExitStatus {
        switch ControlErrorCode(rawValue: error.code) {
        case .policyDenied?: .policyDenied
        case .backendUnavailable?, .agentUnavailable?, .protoUnsupported?: .unavailable
        case .busy?, .invalidState?, .macLocked?, .insufficientSpace?: .tempFail
        case .invalidParams?, .methodNotFound?: .usage
        default: .failure
        }
    }
}
