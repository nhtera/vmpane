import Foundation
import Testing

@testable import VMPaneCore

private func object(_ json: String) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
}

/// The seed lays the whole disk out as Omarchy's installer would (its 2 GiB ESP, the rest btrfs), boots arm64's Limine,
/// names the host and the time zone, and carries the password only as its hash.
@Test func theOmarchySeedLaysOutTheDiskAndCarriesTheHashOnly() throws {
    let hash = SHA512Crypt.hash("s3cret", salt: "abcdefgh")
    let seed = try OmarchySeed(
        hostName: "omarchy-vm", userName: "tien", passwordHash: hash, sshKey: " ssh-ed25519 AAAA tien@mac\n", diskBytes: 40 << 30,
        timeZone: "Asia/Saigon")
    let configuration = try object(seed.userConfiguration)
    #expect(configuration["hostname"] as? String == "omarchy-vm" && configuration["timezone"] as? String == "Asia/Saigon")
    #expect(configuration["kernels"] as? [String] == ["linux-omarchy"])
    let boot = (configuration["omarchy_install"] as? [String: Any])?["boot"] as? [String: Any]
    #expect(boot?["efi_binary"] as? String == "limine_aa64.efi")
    let disk = try #require(((configuration["disk_config"] as? [String: Any])?["device_modifications"] as? [[String: Any]])?.first)
    #expect(disk["device"] as? String == "/dev/vda" && disk["wipe"] as? Bool == true)
    let partitions = try #require(disk["partitions"] as? [[String: Any]])
    func bytes(_ partition: [String: Any], _ key: String) -> UInt64 { ((partition[key] as? [String: Any])?["value"] as? UInt64) ?? 0 }
    #expect(partitions.count == 2)
    #expect(partitions[0]["fs_type"] as? String == "fat32" && partitions[0]["mountpoint"] as? String == "/boot")
    #expect(bytes(partitions[0], "start") == 1 << 20 && bytes(partitions[0], "size") == 2 << 30)
    #expect(partitions[1]["fs_type"] as? String == "btrfs")
    #expect(bytes(partitions[1], "start") == (2 << 30) + (1 << 20), "right after the ESP")
    #expect(bytes(partitions[1], "size") == (40 << 30) - (2 << 30) - (2 << 20), "to 1 MiB before the end")

    let credentials = try object(seed.userCredentials)
    let user = try #require((credentials["users"] as? [[String: Any]])?.first)
    #expect(user["username"] as? String == "tien" && user["sudo"] as? Bool == true && user["enc_password"] as? String == hash)
    #expect(!seed.userConfiguration.contains("s3cret") && !seed.userCredentials.contains("s3cret"))
    #expect(seed.sshKey == "ssh-ed25519 AAAA tien@mac", "trimmed")
    #expect(seed.userConfiguration == seed.userConfiguration, "deterministic")
    let eight: UInt64 = 8 << 30
    func make(host: String = "h", user: String = "u", key: String? = nil, disk: UInt64 = eight, zone: String = "UTC") throws
        -> OmarchySeed
    {
        try OmarchySeed(hostName: host, userName: user, passwordHash: hash, sshKey: key, diskBytes: disk, timeZone: zone)
    }
    #expect(try make(zone: "Mars/Olympus").timeZone == "UTC")
    #expect(throws: CloudInitSeed.Problem.diskTooSmall) { try make(disk: 4 << 30) }
    #expect(throws: CloudInitSeed.Problem.userName) { try make(user: "Root") }
    #expect(throws: CloudInitSeed.Problem.hostName) { try make(host: "a b") }
    #expect(throws: CloudInitSeed.Problem.sshKey) { try make(key: "not a key") }
}

/// The files are private (0600 in a 0700 folder), the key goes only when there is one, the ISO is beside the folder,
/// and a clone's reissue (no `meta-data` to renew) still makes the ISO again.
@Test func theOmarchySeedIsWrittenPrivatelyWithItsKey() throws {
    let root = URL(fileURLWithPath: "/tmp/vp-oseed-\(UUID().uuidString.prefix(8))", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let folder = root.appendingPathComponent("cidata", isDirectory: true)
    let mode = { (url: URL) in try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int }
    let fm = FileManager.default

    let plain = try OmarchySeed(hostName: "h", userName: "u", passwordHash: "x", diskBytes: 8 << 30)
    let iso = try plain.write(to: folder)
    #expect(iso == root.appendingPathComponent("cidata.iso") && fm.fileExists(atPath: iso.path))
    #expect(try mode(iso) == 0o600 && mode(folder) == 0o700)
    for name in ["user_configuration.json", "user_credentials.json", "user_encrypt_installation.txt"] {
        #expect(try mode(folder.appendingPathComponent(name)) == 0o600, "\(name)")
    }
    #expect(try String(contentsOf: folder.appendingPathComponent("user_encrypt_installation.txt"), encoding: .utf8) == "false\n")
    #expect(!fm.fileExists(atPath: folder.appendingPathComponent("authorized_keys").path), "no key, no file: Omarchy keeps SSH off")

    let keyed = try OmarchySeed(hostName: "h", userName: "u", passwordHash: "x", sshKey: "ssh-ed25519 AAAA u@m", diskBytes: 8 << 30)
    _ = try keyed.write(to: folder)
    #expect(try String(contentsOf: folder.appendingPathComponent("authorized_keys"), encoding: .utf8) == "ssh-ed25519 AAAA u@m\n")
    try fm.removeItem(at: iso)
    #expect(try CloudInitSeed.reissue(folder) == iso && fm.fileExists(atPath: iso.path))
    CloudInitSeed.remove(folder)
    #expect(!fm.fileExists(atPath: folder.path) && !fm.fileExists(atPath: iso.path))
}
