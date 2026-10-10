/// Error codes of the control protocol: JSON-RPC's standard codes plus VMPane's (-32010…-32017).
public enum ControlErrorCode: Int, Codable, Sendable, CaseIterable {
    case parseError = -32700
    case invalidRequest = -32600
    case methodNotFound = -32601
    case invalidParams = -32602
    case internalError = -32603
    case backendUnavailable = -32010
    case invalidState = -32011
    case policyDenied = -32012
    case agentUnavailable = -32013
    case busy = -32014
    case unsupportedLive = -32015
    case insufficientSpace = -32016
    case protoUnsupported = -32017
}
