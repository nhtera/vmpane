import Foundation
import VMPaneControl
import VMPaneCore

/// Shared folders inside the guest. VZ serves them over virtiofs (`VZMaterializer`): macOS guests mount them by
/// themselves (/Volumes/My Shared Files); a Linux guest's agent mounts the `vmpane-shares` tag at /mnt/vmpane,
/// one folder per share, each time it connects.
extension HelperController {
    static let linuxSharesMount = "/mnt/vmpane"

    func mountShares(_ connection: AgentConnection, peer: AgentConnection.Peer) async {
        guard backend?.kind == .vz, peer.hello.os == "linux", peer.hello.caps?.contains(AgentCap.exec) == true else { return }
        let mount = Self.linuxSharesMount
        let script = "mountpoint -q \(mount) || { mkdir -p \(mount) && mount -t virtiofs \(VZShareTag.shares) \(mount); }"
        do {
            let result = try await agentExecs.run(
                AgentExecStartParams(shell: script, as: .admin, timeoutMs: 15000), on: connection)
            if result.exited?.code != 0 {
                let message = String(bytes: result.stderr, encoding: .utf8) ?? ""
                Self.log.error("mounting the shared folders failed: \(message, privacy: .public)")
            }
        } catch {
            Self.log.error("mounting the shared folders failed: \(String(describing: error), privacy: .public)")
        }
    }
}

/// The virtiofs tags VMPane's VZ guests see (mirrors `VZPlan`, which VMPaneHost does not link).
enum VZShareTag {
    static let shares = "vmpane-shares"
}
