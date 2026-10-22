import CoreServices
import Foundation
import Security

/// The guest password agents may sign a VM in with (`mcp.signIn`): entered in the app, read only by the VM's
/// helper, which types it into the guest itself. No agent ever sees it.
public protocol GuestCredentialStore: Sendable {
    func password(for vm: UUID) throws -> String?
    /// Whether one is kept, without reading it.
    func has(_ vm: UUID) -> Bool
    func save(_ password: String, for vm: UUID, name: String) throws
    func delete(for vm: UUID) throws
}

public struct GuestCredentialError: Error, CustomStringConvertible, Sendable {
    public let description: String
}

public enum GuestCredentials {
    /// Developer ID builds: the login Keychain, readable without a question by VMPane and its VM helper only.
    /// Other builds (ad hoc: the signature changes with every build, so the Keychain would ask every time) never
    /// touch the Keychain: a file only this user can read, in VMPane's folder.
    public static func store(paths: VMPanePaths) -> GuestCredentialStore {
        teamSigned
            ? KeychainGuestCredentials()
            : FileGuestCredentials(directory: paths.root.appendingPathComponent("sign-in", isDirectory: true))
    }

    /// Whether this process is signed with a team (Developer ID), not ad hoc.
    static let teamSigned: Bool = {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return false }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return false }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess
        else { return false }
        return (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] is String
    }()
}

/// Generic passwords in the login Keychain (service `app.vmpane.guest-sign-in`, account the VM's id), whose
/// access list trusts VMPane and its VM helper: a list entry holds the app's designated requirement (its identifier
/// and team), so updates and the helper's runtime copies read it without a question; anything else is asked about.
struct KeychainGuestCredentials: GuestCredentialStore {
    static let service = "app.vmpane.guest-sign-in"

    private func query(_ vm: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service,
            kSecAttrAccount as String: vm.uuidString.lowercased(),
        ]
    }

    /// Never asks: an app the item does not trust gets an error instead of a Keychain dialog.
    func password(for vm: UUID) throws -> String? {
        var query = query(vm)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        (LegacyKeychain.self as TrustedAccess.Type).forbidQuestions(&query)
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw Self.error("read", status) }
        return String(data: data, encoding: .utf8)
    }

    /// Written by the app (a new VM) or by a VM's helper (its settings): trusted are VMPane and the VM helper inside
    /// it, whichever writes (the helper runs from a runtime copy, so it finds the app by its bundle id), and the writer.
    func save(_ password: String, for vm: UUID, name: String) throws {
        try delete(for: vm)
        var item = query(vm)
        item[kSecValueData as String] = Data(password.utf8)
        item[kSecAttrLabel as String] = "VMPane sign-in: \(name)"
        item[kSecAttrDescription as String] = "Password VMPane types to sign in to the VM"
        if let access = (LegacyKeychain.self as TrustedAccess.Type).access(label: "VMPane sign-in", trusting: Self.trustedApps()) {
            item[kSecAttrAccess as String] = access
        }
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw Self.error("save", status) }
    }

    /// VMPane, its VM helper, and the writing process's own bundle (an entry holds each one's designated requirement).
    static func trustedApps(main: Bundle = .main) -> [URL] {
        let installed = LSCopyApplicationURLsForBundleIdentifier(VMPane.SigningIdentifier.app as CFString, nil)?.takeRetainedValue()
        let app = main.bundleIdentifier == VMPane.SigningIdentifier.app ? main.bundleURL : (installed as? [URL])?.first
        var apps = [main.bundleURL]
        if let app {
            apps += [app, app.appendingPathComponent("Contents/Helpers/VMPaneVM.app", isDirectory: true)]
        }
        var seen = Set<String>()
        return apps.filter { FileManager.default.fileExists(atPath: $0.path) && seen.insert($0.standardizedFileURL.path).inserted }
    }

    func has(_ vm: UUID) -> Bool {
        var query = query(vm)
        query[kSecReturnAttributes as String] = true
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    func delete(for vm: UUID) throws {
        let status = SecItemDelete(query(vm) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Self.error("delete", status) }
    }

    private static func error(_ action: String, _ status: OSStatus) -> GuestCredentialError {
        let text = SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)"
        return GuestCredentialError(description: "cannot \(action) the sign-in password in the Keychain: \(text)")
    }
}

/// An item's access list naming the apps that may read it. The file-based Keychain's API for it is deprecated, yet
/// it is the only way to share an item between two apps without a provisioning profile; called through this
/// protocol so the deprecation does not fail a build with warnings as errors.
private protocol TrustedAccess {
    static func access(label: String, trusting apps: [URL]) -> SecAccess?
    /// Makes a query fail rather than show a Keychain dialog.
    static func forbidQuestions(_ query: inout [String: Any])
}

private enum LegacyKeychain: TrustedAccess {
    @available(macOS, deprecated: 11.0)
    static func forbidQuestions(_ query: inout [String: Any]) {
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
    }

    @available(macOS, deprecated: 10.10)
    static func access(label: String, trusting apps: [URL]) -> SecAccess? {
        var trusted: [SecTrustedApplication] = []
        for app in apps {
            var entry: SecTrustedApplication?
            if SecTrustedApplicationCreateFromPath(app.path, &entry) == errSecSuccess, let entry { trusted.append(entry) }
        }
        var access: SecAccess?
        guard !trusted.isEmpty, SecAccessCreate(label as CFString, trusted as CFArray, &access) == errSecSuccess else { return nil }
        return access
    }
}

/// Dev builds: one 0600 file per VM in a 0700 folder (`sign-in/<vm id>`).
struct FileGuestCredentials: GuestCredentialStore {
    let directory: URL

    private func file(_ vm: UUID) -> URL { directory.appendingPathComponent(vm.uuidString.lowercased()) }

    func password(for vm: UUID) throws -> String? {
        guard let data = FileManager.default.contents(atPath: file(vm).path) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func has(_ vm: UUID) -> Bool { FileManager.default.fileExists(atPath: file(vm).path) }

    func save(_ password: String, for vm: UUID, name: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let target = file(vm)
        let partial = directory.appendingPathComponent(".\(target.lastPathComponent).\(UUID().uuidString)")
        let fd = open(partial.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            throw GuestCredentialError(description: "cannot save the sign-in password: \(String(cString: strerror(errno)))")
        }
        let bytes = Array(password.utf8)
        let written = bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        close(fd)
        guard written == bytes.count, rename(partial.path, target.path) == 0 else {
            unlink(partial.path)
            throw GuestCredentialError(description: "cannot save the sign-in password")
        }
    }

    func delete(for vm: UUID) throws {
        guard unlink(file(vm).path) == 0 || errno == ENOENT else {
            throw GuestCredentialError(description: "cannot delete the sign-in password: \(String(cString: strerror(errno)))")
        }
    }
}
