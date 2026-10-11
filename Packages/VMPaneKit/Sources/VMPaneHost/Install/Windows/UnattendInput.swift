import Foundation

public enum UnattendError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The user has not accepted Microsoft's licence terms in VMPane: Setup's `AcceptEula` stays unset.
    case eulaNotAccepted
    case invalidComputerName(String)
    case invalidUserName(String)
    case invalidProductKey
    case invalidLocale(String)
    /// XML cannot carry control characters.
    case invalidPassword

    public var description: String {
        switch self {
        case .eulaNotAccepted: "Microsoft's licence terms have not been accepted"
        case .invalidComputerName(let name): "\"\(name)\" is not a valid computer name (1–15 letters, digits or hyphens)"
        case .invalidUserName(let name): "\"\(name)\" is not a valid Windows user name"
        case .invalidProductKey: "a product key looks like XXXXX-XXXXX-XXXXX-XXXXX-XXXXX"
        case .invalidLocale(let locale): "\"\(locale)\" is not a language tag such as en-US"
        case .invalidPassword: "the password contains control characters"
        }
    }
}

/// What an unattended Windows 11 install needs from the wizard.
public struct UnattendInput: Sendable, Equatable {
    /// Display language, formats and keyboard, as a language tag (`en-US`, `vi-VN`).
    public var locale: String
    public var inputLocale: String
    /// A Windows time zone id (`SE Asia Standard Time`); see `windowsTimeZone(for:)`.
    public var timeZone: String
    public var computerName: String
    public var userName: String
    /// Ends up in plain text in the unattend image only (deleted by `finalize`) and is removed from the guest.
    public var password: String
    public var editionName: String
    /// Nil: Microsoft's generic install key for the edition (installs, does not activate).
    public var productKey: String?
    /// When the user accepted Microsoft's licence terms in VMPane; required.
    public var eulaAcceptedAt: Date?
    /// Only for a VM with its TPM switched off: Setup's hardware check is bypassed (LabConfig).
    public var bypassTPMChecks: Bool

    public init(
        locale: String, inputLocale: String? = nil, timeZone: String, computerName: String, userName: String, password: String,
        editionName: String = "Windows 11 Pro", productKey: String? = nil, eulaAcceptedAt: Date?, bypassTPMChecks: Bool = false
    ) {
        self.locale = locale
        self.inputLocale = inputLocale ?? locale
        self.timeZone = timeZone
        self.computerName = computerName
        self.userName = userName
        self.password = password
        self.editionName = editionName
        self.productKey = productKey
        self.eulaAcceptedAt = eulaAcceptedAt
        self.bypassTPMChecks = bypassTPMChecks
    }

    /// Microsoft's published generic install keys (they select the edition; they do not activate Windows).
    static let genericKeys: [String: String] = [
        "Windows 11 Pro": "VK7JG-NPHTM-C97JM-9MPGT-3V66T",
        "Windows 11 Home": "YTMG3-N6DKC-DKB77-7M9GH-8HVX7",
        "Windows 11 Pro for Workstations": "DXG7C-N36C4-C4HTG-X4T3X-2YV77",
        "Windows 11 Education": "YNMGQ-8RYV3-4PGQ3-C8XTP-7CFBY",
    ]

    /// This input in a language the image has: Setup stops at its language page for any other (an en-US ISO on a
    /// Mac set to en-GB or en-VN), so the Mac's language is kept only when the image installs it, and otherwise
    /// the image's default is used (formats and keyboard can be changed in Windows). Unknown languages: unchanged.
    func speaking(_ languages: [String]) -> UnattendInput {
        guard let fallback = languages.first else { return self }
        func pick(_ tag: String) -> String { languages.first { $0.caseInsensitiveCompare(tag) == .orderedSame } ?? fallback }
        var input = self
        input.locale = pick(locale)
        input.inputLocale = pick(inputLocale)
        return input
    }

    /// Checks everything Setup would otherwise reject halfway through an unattended install.
    func validate() throws {
        guard eulaAcceptedAt != nil else { throw UnattendError.eulaNotAccepted }
        for tag in [locale, inputLocale] where !Self.isLanguageTag(tag) { throw UnattendError.invalidLocale(tag) }
        // NetBIOS: at most 15 characters, letters, digits and hyphens, not only digits.
        let allowedName = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")
        guard (1...15).contains(computerName.count), computerName.unicodeScalars.allSatisfy(allowedName.contains),
            !computerName.allSatisfy(\.isNumber), !computerName.hasPrefix("-")
        else { throw UnattendError.invalidComputerName(computerName) }
        // Local account names: at most 20 characters, none of "/\[]:;|=,+*?<>@ or control characters, not only dots or
        // spaces, not a built-in account.
        let forbidden = CharacterSet(charactersIn: "\"/\\[]:;|=,+*?<>@").union(.controlCharacters)
        guard (1...20).contains(userName.count), !userName.unicodeScalars.contains(where: forbidden.contains),
            !userName.allSatisfy({ $0 == "." || $0 == " " }),
            !["administrator", "guest", "defaultaccount", "wdagutilityaccount"].contains(userName.lowercased())
        else { throw UnattendError.invalidUserName(userName) }
        guard !password.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw UnattendError.invalidPassword }
        if let productKey {
            let groups = productKey.split(separator: "-", omittingEmptySubsequences: false)
            guard groups.count == 5, groups.allSatisfy({ $0.count == 5 && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) } })
            else { throw UnattendError.invalidProductKey }
        }
    }

    static func isLanguageTag(_ tag: String) -> Bool {
        let parts = tag.split(separator: "-", omittingEmptySubsequences: false)
        return (2...3).contains(parts.count)
            && parts.allSatisfy { (2...4).contains($0.count) && $0.allSatisfy { $0.isASCII && $0.isLetter } }
    }

    /// The Windows time zone id for an IANA one (ICU's CLDR mapping); `UTC` when there is none.
    public static func windowsTimeZone(for identifier: String = TimeZone.current.identifier) -> String {
        typealias Convert =
            @convention(c) (UnsafePointer<UInt16>, Int32, UnsafeMutablePointer<UInt16>, Int32, UnsafeMutablePointer<Int32>) -> Int32
        guard let icu = dlopen("/usr/lib/libicucore.A.dylib", RTLD_NOW | RTLD_NOLOAD) ?? dlopen("/usr/lib/libicucore.A.dylib", RTLD_NOW),
            let symbol = dlsym(icu, "ucal_getWindowsTimeZoneID")
        else { return "UTC" }
        let convert = unsafeBitCast(symbol, to: Convert.self)
        let source = Array(identifier.utf16)
        var output = [UInt16](repeating: 0, count: 128)
        var status: Int32 = 0
        let length = source.withUnsafeBufferPointer { buffer -> Int32 in
            guard let base = buffer.baseAddress else { return 0 }
            return convert(base, Int32(buffer.count), &output, Int32(output.count), &status)
        }
        guard status <= 0, length > 0 else { return "UTC" }
        return String(decoding: output.prefix(Int(length)), as: UTF16.self)
    }
}
