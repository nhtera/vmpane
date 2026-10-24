import CryptoKit
import Foundation

extension AgentConfig {
    /// `autoUpdate`, its default applied: the guest tools update from VMPane's.
    public var updatesTools: Bool {
        get { autoUpdate ?? true }
        set { autoUpdate = newValue ? nil : false }
    }
}

/// The guest tools an agent update installs: a runtime copy's `GuestTools/linux` (the agent, `install.sh` and its
/// units) or `GuestTools/windows` (`vmpane-agent.msi`), every file checked against the folder's `SHA256SUMS` before
/// any of it goes to a guest.
public struct GuestToolsPackage: Sendable, Equatable {
    public let folder: URL
    /// The files to send, as `SHA256SUMS` names them.
    public let files: [String]
    /// Their SHA-256 digests (lowercase hex), by name.
    public let sha256: [String: String]

    public struct Problem: Error, CustomStringConvertible, Equatable {
        public let description: String
    }

    /// The file the update runs: Linux's install script, Windows' installer.
    public static func installer(for os: GuestOS) -> String? {
        switch os {
        case .linux: "install.sh"
        case .windows: "vmpane-agent.msi"
        case .macos: nil  // its pkg takes the agent down first: not yet tried through the agent
        }
    }

    public static func folder(for os: GuestOS, runtime: URL) -> URL {
        runtime.appendingPathComponent("GuestTools/\(os.rawValue)", isDirectory: true)
    }

    /// The package for `os` in `runtime` (`runtime/<version>/`), or why there is none to send.
    public static func verified(_ os: GuestOS, runtime: URL) throws -> GuestToolsPackage {
        guard let installer = installer(for: os) else { throw Problem(description: "\(os.rawValue) guests update their tools by hand") }
        let folder = folder(for: os, runtime: runtime)
        guard let sums = try? String(contentsOf: folder.appendingPathComponent("SHA256SUMS"), encoding: .utf8) else {
            throw Problem(description: "this VMPane has no \(os.rawValue) guest tools")
        }
        var files: [String] = []
        var digests: [String: String] = [:]
        for line in sums.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: " ", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard fields.count == 2 else { continue }
            let name = fields[1].hasPrefix("*") ? String(fields[1].dropFirst()) : fields[1]
            guard !name.contains("/"), name != "..", name != "." else { throw Problem(description: "SHA256SUMS names \(name)") }
            guard let digest = sha256(of: folder.appendingPathComponent(name)), digest == fields[0].lowercased() else {
                throw Problem(description: "\(name) does not match its checksum")
            }
            files.append(name)
            digests[name] = digest
        }
        guard files.contains(installer) else { throw Problem(description: "the \(os.rawValue) guest tools have no \(installer)") }
        return GuestToolsPackage(folder: folder, files: files, sha256: digests)
    }

    static func sha256(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try? handle.read(upToCount: 1 << 20), !data.isEmpty { hasher.update(data: data) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
