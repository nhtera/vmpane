import Foundation
import Security

/// The code signature of a connected peer process.
public struct CodeIdentity: Sendable, Equatable {
    public let identifier: String?
    public let teamID: String?
    public let isAdHoc: Bool
}

/// Code-signing checks of control-socket peers, by audit token (not pid, which can be reused).
/// Production requirement: identifier + Team ID + Apple anchor. Development (ad hoc) builds have no team,
/// so callers fall back to identifier checks there (see Phase 10 for enforcement).
public enum PeerIdentity {
    /// Designated requirement for one of our binaries signed by `teamID`.
    public static func requirement(identifier: String, teamID: String) -> String {
        "identifier \"\(identifier)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\""
    }

    /// The peer's signing identifier and team, if its code is valid.
    public static func identity(auditToken: Data) -> CodeIdentity? {
        guard let code = guestCode(auditToken), SecCodeCheckValidity(code, [], nil) == errSecSuccess else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
            let dictionary = info as? [String: Any]
        else { return nil }
        let flags = (dictionary[kSecCodeInfoFlags as String] as? UInt32) ?? 0
        return CodeIdentity(
            identifier: dictionary[kSecCodeInfoIdentifier as String] as? String,
            teamID: dictionary[kSecCodeInfoTeamIdentifier as String] as? String,
            isAdHoc: flags & SecCodeSignatureFlags.adhoc.rawValue != 0)
    }

    /// Whether the peer's running code satisfies `requirement` (code-signing requirement language).
    public static func satisfies(auditToken: Data, requirement: String) -> Bool {
        guard let code = guestCode(auditToken) else { return false }
        var parsed: SecRequirement?
        guard SecRequirementCreateWithString(requirement as CFString, [], &parsed) == errSecSuccess, let parsed else { return false }
        return SecCodeCheckValidity(code, [], parsed) == errSecSuccess
    }

    private static func guestCode(_ auditToken: Data) -> SecCode? {
        var code: SecCode?
        let attributes = [kSecGuestAttributeAudit: auditToken] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess else { return nil }
        return code
    }
}
