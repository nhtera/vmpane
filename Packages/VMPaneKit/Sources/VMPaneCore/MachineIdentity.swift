import Foundation

/// Per-VM hardware identity: what a clone (or a Finder copy) must not share with its original.
public enum MachineIdentity {
    /// A random locally administered unicast MAC (`x2:…`, `x6:…`, `xA:…` or `xE:…`), lower-case hex.
    public static func randomMACAddress() -> String {
        var bytes = (0..<6).map { _ in UInt8.random(in: 0...255) }
        bytes[0] = (bytes[0] | 0x02) & 0xFE
        return bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
    }

    /// Normalised (lower-case) form of a MAC for comparisons.
    public static func normalizedMAC(_ mac: String) -> String { mac.lowercased() }
}
