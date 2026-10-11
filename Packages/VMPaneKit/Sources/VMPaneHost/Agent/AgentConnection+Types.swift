import Foundation
import VMPaneControl
import VMPaneCore

extension AgentConnection {
    public struct Peer: Sendable, Equatable {
        public var hello: AgentHelloParams
        public var proto: UInt32
    }

    public enum ConnectionError: Error, Equatable, Sendable, CustomStringConvertible {
        case violation(String)
        case closed(String)
        case timeout
        /// The agent refused or failed the request.
        case rpc(RPCError)

        public var description: String {
            switch self {
            case .violation(let why): "agent protocol violation: \(why)"
            case .closed(let why): "agent connection closed: \(why)"
            case .timeout: "the agent did not answer in time"
            case .rpc(let error): error.message
            }
        }
    }

    public struct CallResult: Sendable {
        public var result: JSONValue
        /// Guest → host streams named in the result, keyed by id.
        public var inbound: [UInt32: AgentInbound]
    }

    /// Which ids of a result name streams: data the guest sends, and data the host sends (exec stdin).
    public struct StreamNames: Sendable {
        public var inbound: @Sendable (JSONValue) -> [UInt32]
        public var outbound: @Sendable (JSONValue) -> [UInt32]

        public init(
            inbound: @escaping @Sendable (JSONValue) -> [UInt32] = { _ in [] },
            outbound: @escaping @Sendable (JSONValue) -> [UInt32] = { _ in [] }
        ) {
            self.inbound = inbound
            self.outbound = outbound
        }

        public static let none = StreamNames()
    }

    /// A request on its way; `response` waits for it.
    public struct PendingCall: Sendable {
        let id: Int64
    }
}
