import Foundation

/// File names that come from elsewhere (a guest, a client) made safe to use as path components here.
public enum SafeName {
    /// `name` as one safe path component (Unicode NFC), or nil: empty, `.`/`..`, separators (`/`, `:`, `\`),
    /// control characters, and names over 255 bytes are refused; surrounding spaces are trimmed.
    public static func component(_ name: String) -> String? {
        let clean = name.precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty, clean != ".", clean != "..", clean.utf8.count <= 255 else { return nil }
        guard !clean.unicodeScalars.contains(where: { $0 == "/" || $0 == ":" || $0 == "\\" || CharacterSet.controlCharacters.contains($0) })
        else { return nil }
        return clean
    }

    /// The components of a relative "/"-separated path, each a plain name (no ".", "..", NUL or "\"), NFC; nil if
    /// any is not.
    public static func components(_ path: String) -> [String]? {
        var parts: [String] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            let name = String(part).precomposedStringWithCanonicalMapping
            guard name != ".", name != "..", !name.contains("\0"), !name.contains("\\"), name.utf8.count <= 255 else { return nil }
            parts.append(name)
        }
        return parts
    }
}
