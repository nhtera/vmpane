import Darwin
import Foundation
import Testing

@testable import VMPaneControl

private func peer(_ pid: pid_t, uid: uid_t = getuid()) -> PeerCredentials {
    PeerCredentials(uid: uid, pid: pid, auditToken: Data([UInt8(truncatingIfNeeded: pid)]))
}

/// Signatures by pid: pid 10 the app, 11 the CLI, 12 the itest bridge, 13 an impostor claiming the app's
/// identifier with another team, 14 unsigned.
private func classifier(team: String?, adHoc: Bool, peersAdHoc: Bool) -> PeerClassifier {
    let signatures: [pid_t: CodeIdentity] = [
        10: CodeIdentity(identifier: "app.vmpane.mac", teamID: peersAdHoc ? nil : "TEAM", isAdHoc: peersAdHoc),
        11: CodeIdentity(identifier: "app.vmpane.mac.cli", teamID: peersAdHoc ? nil : "TEAM", isAdHoc: peersAdHoc),
        12: CodeIdentity(identifier: "app.vmpane.mac.itest", teamID: nil, isAdHoc: true),
        13: CodeIdentity(identifier: "app.vmpane.mac", teamID: "OTHER", isAdHoc: false),
    ]
    return PeerClassifier(
        selfPID: 99, selfTeamID: team, selfIsAdHoc: adHoc,
        identify: { signatures[$0.pid] },
        satisfies: { peer, requirement in
            guard let code = signatures[peer.pid], let team = code.teamID else { return false }
            return requirement.contains("\"\(code.identifier ?? "")\"") && requirement.contains("\"\(team)\"")
        })
}

@Test func releaseHelpersTrustOnlyTheirTeam() {
    let release = classifier(team: "TEAM", adHoc: false, peersAdHoc: false)
    #expect(release.classify(peer(99)) == .ui, "its own window")
    #expect(release.classify(peer(10)) == .ui)
    #expect(release.classify(peer(11)) == .cli)
    #expect(release.classify(peer(12)) == .other, "the itest bridge is never honoured by a release helper")
    #expect(release.classify(peer(13)) == .other, "the app's identifier signed by someone else")
    #expect(release.classify(peer(14)) == .other)
    #expect(release.classify(peer(10, uid: getuid() + 1)) == .other, "another user")
}

@Test func developmentHelpersGoByIdentifier() {
    let development = classifier(team: nil, adHoc: true, peersAdHoc: true)
    #expect(development.classify(peer(10)) == .ui)
    #expect(development.classify(peer(11)) == .cli)
    #expect(development.classify(peer(12)) == .itest)
    #expect(development.classify(peer(13)) == .other, "not ad hoc")
    #expect(development.classify(peer(14)) == .other)
}

@Test func thisProcessHasASignatureToCompareWith() {
    // The test runner is signed (ad hoc at least); the classifier reads it.
    #expect(PeerIdentity.selfIdentity() != nil)
}
