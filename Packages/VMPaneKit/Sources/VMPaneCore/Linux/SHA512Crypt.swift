import CryptoKit
import Foundation

/// `$6$` password hashes (SHA-crypt, as glibc's crypt(3) and cloud-init's `passwd` take them): what a guest's
/// /etc/shadow holds, so a seed carries the hash, never the password.
public enum SHA512Crypt {
    static let alphabet = Array("./0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz".utf8)
    public static let defaultRounds = 5000

    /// A hash with a fresh random 16-character salt.
    public static func hash(_ password: String) -> String {
        var generator = SystemRandomNumberGenerator()
        let salt =
            String(bytes: (0..<16).map { _ in alphabet[Int(generator.next(upperBound: UInt(alphabet.count)))] }, encoding: .ascii) ?? ""
        return hash(password, salt: salt)
    }

    /// The hash of `password` with `salt` (at most 16 characters are used) and `rounds` (the default is not written).
    public static func hash(_ password: String, salt: String, rounds: Int = defaultRounds) -> String {
        let key = Array(password.utf8)
        let salt = Array(salt.utf8.prefix(16))
        let rounds = min(max(rounds, 1000), 999_999_999)
        func sha(_ parts: [UInt8]...) -> [UInt8] {
            var hasher = SHA512()
            for part in parts { hasher.update(data: part) }
            return Array(hasher.finalize())
        }
        let b = sha(key, salt, key)
        var a = SHA512()
        a.update(data: key)
        a.update(data: salt)
        var length = key.count
        while length > 64 {
            a.update(data: b)
            length -= 64
        }
        a.update(data: Array(b.prefix(length)))
        length = key.count
        while length > 0 {
            a.update(data: length & 1 != 0 ? b : key)
            length >>= 1
        }
        var digest = Array(a.finalize())
        var keyHash = SHA512()
        for _ in 0..<key.count { keyHash.update(data: key) }
        let pBytes = repeated(Array(keyHash.finalize()), count: key.count)
        var saltHash = SHA512()
        for _ in 0..<(16 + Int(digest[0])) { saltHash.update(data: salt) }
        let sBytes = repeated(Array(saltHash.finalize()), count: salt.count)
        for round in 0..<rounds {
            var step = SHA512()
            step.update(data: round & 1 != 0 ? pBytes : digest)
            if round % 3 != 0 { step.update(data: sBytes) }
            if round % 7 != 0 { step.update(data: pBytes) }
            step.update(data: round & 1 != 0 ? digest : pBytes)
            digest = Array(step.finalize())
        }
        // The digest's bytes in the order the encoding takes them, three at a time.
        let order = [
            0, 21, 42, 22, 43, 1, 44, 2, 23, 3, 24, 45, 25, 46, 4, 47, 5, 26, 6, 27, 48, 28, 49, 7, 50, 8, 29, 9, 30, 51, 31, 52, 10,
            53, 11, 32, 12, 33, 54, 34, 55, 13, 56, 14, 35, 15, 36, 57, 37, 58, 16, 59, 17, 38, 18, 39, 60, 40, 61, 19, 62, 20, 41,
        ]
        var encoded = ""
        for start in stride(from: 0, to: order.count, by: 3) {
            let bytes = order[start..<start + 3].map { UInt32(digest[$0]) }
            encoded += base64(bytes[0] << 16 | bytes[1] << 8 | bytes[2], count: 4)
        }
        encoded += base64(UInt32(digest[63]), count: 2)
        let roundsPart = rounds == defaultRounds ? "" : "rounds=\(rounds)$"
        return "$6$\(roundsPart)\(String(bytes: salt, encoding: .utf8) ?? "")$\(encoded)"
    }

    private static func repeated(_ bytes: [UInt8], count: Int) -> [UInt8] {
        (0..<count).map { bytes[$0 % 64] }
    }

    private static func base64(_ value: UInt32, count: Int) -> String {
        var value = value
        var text = ""
        for _ in 0..<count {
            text.append(Character(UnicodeScalar(alphabet[Int(value & 0x3F)])))
            value >>= 6
        }
        return text
    }
}
