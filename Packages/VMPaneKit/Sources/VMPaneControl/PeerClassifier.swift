import Darwin
import Foundation
import Security
import VMPaneCore

/// Who a control-socket peer is, for the policy (Phase 10, Red Team #1). From the peer's code signature, never
/// from what it claims in `helper.hello`:
/// - the helper's own process (its window) and the VMPane app → UI;
/// - the vmpane CLI → CLI (operator only when its own interactive self-check said so; `HelloClaims`);
/// - in an ad hoc signed (development) helper only, the itest bridge (`app.vmpane.mac.itest`) → UI, so integration
///   tests can drive helpers; a Developer ID helper never honours it;
/// - anything else → automated (policy-bound, like MCP).
///
/// Release builds compare the peer against the helper's own Team ID with Apple's anchor; development builds are ad
/// hoc and compare identifiers only (an agent able to sign binaries has a host shell, which the threat model does
/// not constrain; `docs/security-model.md`).
public struct PeerClassifier: Sendable {
    public enum Kind: String, Sendable, Equatable {
        case ui, itest, cli, other
    }

    public static let appIdentifier = "app.vmpane.mac"
    public static let cliIdentifier = "app.vmpane.mac.cli"
    public static let itestIdentifier = "app.vmpane.mac.itest"

    let selfPID: pid_t
    /// The helper's own signature: its Team ID decides release vs development rules.
    let selfTeamID: String?
    let selfIsAdHoc: Bool
    let identify: @Sendable (PeerCredentials) -> CodeIdentity?
    let satisfies: @Sendable (PeerCredentials, String) -> Bool

    /// For this process.
    public static func current() -> PeerClassifier {
        let own = PeerIdentity.selfIdentity()
        return PeerClassifier(
            selfPID: getpid(), selfTeamID: own?.teamID, selfIsAdHoc: own?.isAdHoc ?? true,
            identify: { PeerIdentity.identity(auditToken: $0.auditToken) },
            satisfies: { PeerIdentity.satisfies(auditToken: $0.auditToken, requirement: $1) })
    }

    init(
        selfPID: pid_t, selfTeamID: String?, selfIsAdHoc: Bool, identify: @escaping @Sendable (PeerCredentials) -> CodeIdentity?,
        satisfies: @escaping @Sendable (PeerCredentials, String) -> Bool
    ) {
        self.selfPID = selfPID
        self.selfTeamID = selfTeamID
        self.selfIsAdHoc = selfIsAdHoc
        self.identify = identify
        self.satisfies = satisfies
    }

    public func classify(_ peer: PeerCredentials) -> Kind {
        if peer.pid == selfPID { return .ui }  // the helper's own window, in this process
        guard peer.uid == getuid(), let code = identify(peer), let identifier = code.identifier else { return .other }
        if let team = selfTeamID, !selfIsAdHoc {
            for (id, kind) in [(Self.appIdentifier, Kind.ui), (Self.cliIdentifier, .cli)] where identifier == id {
                return satisfies(peer, PeerIdentity.requirement(identifier: id, teamID: team)) ? kind : .other
            }
            return .other
        }
        guard code.isAdHoc else { return .other }
        switch identifier {
        case Self.appIdentifier: return .ui
        case Self.cliIdentifier: return .cli
        case Self.itestIdentifier: return .itest
        default: return .other
        }
    }
}
