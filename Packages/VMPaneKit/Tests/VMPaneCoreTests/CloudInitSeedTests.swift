import Foundation
import Testing

@testable import VMPaneCore

@Test func sha512CryptMatchesTheSpecVectors() {
    // From "Unix crypt using SHA-256 and SHA-512" (Drepper), the test vectors.
    #expect(
        SHA512Crypt.hash("Hello world!", salt: "saltstring")
            == "$6$saltstring$svn8UoSVapNtMuq1ukKS4tPQd8iKwSMHWjl/O817G3uBnIFNjnQJuesI68u4OTLiBFdcbYEdFCoEOfaS35inz1")
    #expect(
        SHA512Crypt.hash("Hello world!", salt: "saltstringsaltstring", rounds: 10000)
            == "$6$rounds=10000$saltstringsaltst$OW1/O6BYHV6BcXZu8QVeXbDWra3Oeqh0sbHbbMCVNSnCM/UrjmM0Dp8vOuZeHBy/YTBmSK6H9qs/y3RnOaw5v.")
    let fresh = SHA512Crypt.hash("secret")
    #expect(fresh.hasPrefix("$6$") && fresh.count == 3 + 16 + 1 + 86 && fresh != SHA512Crypt.hash("secret"), "a random salt each time")
}

@Test func theSeedCarriesTheHashNeverThePassword() throws {
    let seed = try CloudInitSeed(
        distro: .fedora, hostName: "build-box", userName: "dev", passwordHash: "$6$salt$hash", sshKey: "ssh-ed25519 AAAA dev@mac",
        instanceID: "i-1")
    #expect(seed.metaData == "instance-id: \"i-1\"\nlocal-hostname: \"build-box\"\n")
    let data = seed.userData
    #expect(data.hasPrefix("#cloud-config\n"))
    #expect(data.contains("    passwd: \"$6$salt$hash\"") && data.contains("    groups: [wheel]"))
    #expect(data.contains("      - \"ssh-ed25519 AAAA dev@mac\"") && data.contains("ssh_pwauth: false"), "a key: no SSH passwords")
    #expect(data.contains("vmpane-tools/install.sh"))
    #expect(data.contains("rm -f /var/lib/cloud/instances/*/user-data.txt* /var/lib/cloud/instances/*/cloud-config.txt"))
    #expect(!data.contains("packages:") && !data.contains("power_state"), "a server")

    let desktop = try CloudInitSeed(distro: .ubuntu, hostName: "d", userName: "me", passwordHash: "h", desktop: true)
    #expect(desktop.userData.contains("  - ubuntu-desktop-minimal") && desktop.userData.contains("AutomaticLogin=me"))
    #expect(desktop.userData.contains("ssh_pwauth: true") && desktop.userData.contains("    groups: [sudo]"))
    #expect(desktop.instanceID != (try CloudInitSeed(distro: .ubuntu, hostName: "d", userName: "me", passwordHash: "h")).instanceID)

    // Every value VMPane writes is a quoted string: YAML 1.1 reads 2026 as a number and no as false.
    let numeric = try CloudInitSeed(distro: .debian, hostName: "2026", userName: "no", passwordHash: "h")
    #expect(numeric.userData.contains("hostname: \"2026\"") && numeric.userData.contains("  - name: \"no\""))
    #expect(numeric.userData.contains("AutomaticLogin") == false)
    let debian = try CloudInitSeed(distro: .debian, hostName: "d", userName: "me", passwordHash: "h", desktop: true)
    #expect(debian.userData.contains("> /etc/gdm3/daemon.conf"), "Debian's gdm3 reads daemon.conf")
    for name in ["Root", "a b", "", "x\"y", String(repeating: "a", count: 33), "1user", "sudo", "www-data", "systemd-network"] {
        #expect(throws: CloudInitSeed.Problem.userName) {
            try CloudInitSeed(distro: .debian, hostName: "h", userName: name, passwordHash: "h")
        }
    }
    for key in ["ssh-rsa A\nruncmd: [x]", "ssh-ed25519 AAAA\u{85}x", "not-a-key"] {
        #expect(throws: CloudInitSeed.Problem.sshKey) {
            try CloudInitSeed(distro: .debian, hostName: "h", userName: "u", passwordHash: "h", sshKey: key)
        }
    }
    let fido = "sk-ssh-ed25519@openssh.com AAAA k"
    #expect((try? CloudInitSeed(distro: .debian, hostName: "h", userName: "u", passwordHash: "h", sshKey: fido)) != nil)
    #expect(CloudInitSeed.quoted("a\"b\\c\n") == "\"a\\\"b\\\\c\\x0A\"")
}

@Test func theSeedIsWrittenPrivatelyAndReissuedForAClone() throws {
    let root = URL(fileURLWithPath: "/tmp/vp-seed-\(UUID().uuidString.prefix(8))", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let folder = root.appendingPathComponent("cidata", isDirectory: true)
    let seed = try CloudInitSeed(distro: .ubuntu, hostName: "h", userName: "u", passwordHash: "h", instanceID: "first")
    let iso = try seed.write(to: folder)
    let mode = { (url: URL) in try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int }
    #expect(iso == root.appendingPathComponent("cidata.iso") && FileManager.default.fileExists(atPath: iso.path))
    #expect(try mode(iso) == 0o600 && mode(folder) == 0o700 && mode(folder.appendingPathComponent("user-data")) == 0o600)
    _ = try CloudInitSeed.reissue(folder)
    let meta = try String(contentsOf: folder.appendingPathComponent("meta-data"), encoding: .utf8)
    #expect(!meta.contains("first") && meta.contains("local-hostname: \"h\""), "a new machine for cloud-init")
    CloudInitSeed.remove(folder)
    #expect(!FileManager.default.fileExists(atPath: folder.path) && !FileManager.default.fileExists(atPath: iso.path))
}
