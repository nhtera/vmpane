import Foundation

public enum AutounattendGeneratorError: Error, Equatable, Sendable {
    case missingTemplate
}

/// `autounattend.xml` for an unattended Windows 11 ARM64 install with a local account and no network, the path
/// proven in Gate 00 S1 (zero clicks to the desktop, no Setup bypass: our firmware passes the TPM and Secure
/// Boot checks). The document is `Install/Resources/autounattend.xml` with `{{NAME}}` fields; every value is
/// validated, XML-escaped, and substituted in one pass (a value is never read as a field).
///
/// At the first logon it runs, in order: `install.ps1` from the guest-tools ISO (volume `VMPANE_TOOLS`),
/// power settings (no hibernation, sleep or display blanking: a blanked display shows as a black window),
/// then removes the password Windows keeps from the install (Panther copies, AutoLogon).
public enum AutounattendGenerator {
    /// Volume label of the guest-tools ISO (the template's first-logon command looks for it).
    public static let toolsVolumeLabel = "VMPANE_TOOLS"

    public static func generate(_ input: UnattendInput) throws -> String {
        try input.validate()
        guard let url = Bundle.module.url(forResource: "autounattend", withExtension: "xml", subdirectory: "Resources"),
            let template = try? String(contentsOf: url, encoding: .utf8)
        else { throw AutounattendGeneratorError.missingTemplate }
        let key = input.productKey ?? UnattendInput.genericKeys[input.editionName]
        let fields: [String: String] = [
            "LOCALE": xml(input.locale), "INPUT_LOCALE": xml(input.inputLocale), "EDITION": xml(input.editionName),
            "COMPUTER_NAME": xml(input.computerName), "TIME_ZONE": xml(input.timeZone), "USER": xml(input.userName),
            "PASSWORD": xml(input.password),
            "PRODUCT_KEY": key.map { "        <ProductKey><Key>\(xml($0))</Key><WillShowUI>OnError</WillShowUI></ProductKey>\n" } ?? "",
            "LAB_CONFIG": input.bypassTPMChecks ? labConfig : "",
        ]
        return try fill(template, fields)
    }

    /// Replaces each `{{NAME}}` of `template` once, left to right; text inserted is never scanned again.
    static func fill(_ template: String, _ fields: [String: String]) throws -> String {
        var output = ""
        var rest = template[...]
        while let open = rest.range(of: "{{") {
            output += rest[..<open.lowerBound]
            guard let close = rest[open.upperBound...].range(of: "}}"), let value = fields[String(rest[open.upperBound..<close.lowerBound])]
            else { throw AutounattendGeneratorError.missingTemplate }
            output += value
            rest = rest[close.upperBound...]
        }
        return output + rest
    }

    /// Setup's TPM and Secure Boot checks, bypassed only for a VM without a TPM.
    static let labConfig = """
              <RunSynchronous>
                <RunSynchronousCommand wcm:action="add">
                  <Order>1</Order>
                  <Path>reg.exe add HKLM\\SYSTEM\\Setup\\LabConfig /v BypassTPMCheck /t REG_DWORD /d 1 /f</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                  <Order>2</Order>
                  <Path>reg.exe add HKLM\\SYSTEM\\Setup\\LabConfig /v BypassSecureBootCheck /t REG_DWORD /d 1 /f</Path>
                </RunSynchronousCommand>
              </RunSynchronous>

        """

    /// XML text/attribute escaping.
    static func xml(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}
