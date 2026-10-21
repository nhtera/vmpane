import Foundation

/// Text read from a guest's screen (recognized, or a control's name) as agents get it: it comes from the VM, so it is
/// untrusted. Control and bidirectional formatting characters are dropped (they can hide or reorder what a reader
/// sees), whitespace runs become one space, and it is cut to a length.
public enum GuestText {
    /// Bidirectional overrides, embeddings, isolates and marks.
    static let bidi: Set<Unicode.Scalar> = Set(
        [0x061C, 0x200E, 0x200F, 0x202A, 0x202B, 0x202C, 0x202D, 0x202E, 0x2066, 0x2067, 0x2068, 0x2069].compactMap(Unicode.Scalar.init))

    /// Format characters that words need: the zero-width non-joiner (Persian, Indic scripts) and joiner (emoji).
    static let joiners: Set<Unicode.Scalar> = ["\u{200C}", "\u{200D}"]

    public static func clean(_ text: String, maxLength: Int = 120) -> String {
        var scalars = String.UnicodeScalarView()
        var lastWasSpace = true
        for scalar in text.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                if !lastWasSpace { scalars.append(" ") }
                lastWasSpace = true
            } else if !bidi.contains(scalar), scalar.properties.generalCategory != .control,
                scalar.properties.generalCategory != .format || joiners.contains(scalar)
            {
                scalars.append(scalar)
                lastWasSpace = false
            }
        }
        var cleaned = String(scalars)
        if cleaned.hasSuffix(" ") { cleaned.removeLast() }
        return cleaned.count > maxLength ? String(cleaned.prefix(maxLength - 1)) + "…" : cleaned
    }
}
