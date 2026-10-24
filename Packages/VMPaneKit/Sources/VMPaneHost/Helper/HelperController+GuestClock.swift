import Foundation
import VMPaneControl
import VMPaneCore

extension HelperController {
    /// Sets the guest clock to the host's (after a connect, a resume or a restore the guest's is stale).
    static func syncClock(_ connection: AgentConnection, peer: AgentConnection.Peer) async {
        guard peer.hello.caps?.contains(AgentCap.time) == true else { return }
        let now = Int64(Date().timeIntervalSince1970 * 1_000_000_000)
        do {
            _ = try await connection.call(AgentMethod.timeSet, RPCParams.encode(AgentTimeSetParams(unixNanos: now)).get())
        } catch {
            log.notice("guest clock sync failed: \(String(describing: error), privacy: .public)")
        }
    }
}
