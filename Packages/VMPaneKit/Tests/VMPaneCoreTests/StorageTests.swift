import Foundation
import Testing

@testable import VMPaneCore

@Test func rawDiskIsSparseAndOnlyGrows() throws {
    try withTempDirectory { dir in
        let disk = dir.appendingPathComponent("disk.img")
        let gib: UInt64 = 1 << 30
        try DiskImage.createRaw(at: disk, sizeBytes: 64 * gib)
        #expect(try DiskImage.logicalSize(disk) == 64 * gib)
        #expect(try DiskImage.allocatedBytes(disk) < 1 << 20)
        #expect(throws: (any Error).self) { try DiskImage.createRaw(at: disk, sizeBytes: gib) }

        try DiskImage.grow(disk, to: 80 * gib)
        #expect(try DiskImage.logicalSize(disk) == 80 * gib)
        #expect(throws: DiskImageError.shrinkNotAllowed(current: 80 * gib, requested: gib)) {
            try DiskImage.grow(disk, to: gib)
        }
        let mode = try #require(FileManager.default.attributesOfItem(atPath: disk.path)[.posixPermissions] as? Int)
        #expect(mode == 0o600)
    }
}

@Test func cloneSharesBlocksUntilWritten() throws {
    try withTempDirectory { dir in
        try #require(CloneFile.volumeSupportsCloning(dir), "temp directory is not on APFS")
        let source = dir.appendingPathComponent("disk.img")
        try Data(repeating: 0xAB, count: 4 << 20).write(to: source)
        let clone = dir.appendingPathComponent("clone.img")
        try CloneFile.clone(source, to: clone)
        #expect(try Data(contentsOf: clone) == Data(contentsOf: source))
        if let privateBytes = DiskImage.privateBytes(clone) {
            #expect(privateBytes < 1 << 20, "a fresh clone should own (almost) no blocks")
        }
        #expect(throws: (any Error).self) { try CloneFile.clone(source, to: clone) }  // destination exists
    }
}

@Test func cloneOfADirectoryTreeKeepsSymlinksAsLinks() throws {
    try withTempDirectory { dir in
        let tree = dir.appendingPathComponent("current", isDirectory: true)
        try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: tree.appendingPathComponent("disk.img"))
        try FileManager.default.createSymbolicLink(atPath: tree.appendingPathComponent("link").path, withDestinationPath: "/etc/hosts")
        let copy = dir.appendingPathComponent("copy", isDirectory: true)
        try CloneFile.clone(tree, to: copy)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: copy.appendingPathComponent("link").path) == "/etc/hosts")
    }
}

/// A small FAT disk image mounted for the duration of `body` (no clonefile support there).
private func withFATVolume(_ body: (URL) throws -> Void) throws {
    try withTempDirectory { dir in
        let image = dir.appendingPathComponent("fat.dmg")
        let mount = dir.appendingPathComponent("mnt", isDirectory: true)
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        try run("/usr/bin/hdiutil", ["create", "-quiet", "-size", "8m", "-fs", "MS-DOS", "-volname", "VPFAT", image.path])
        try run("/usr/bin/hdiutil", ["attach", "-quiet", "-nobrowse", "-mountpoint", mount.path, image.path])
        defer { try? run("/usr/bin/hdiutil", ["detach", "-quiet", "-force", mount.path]) }
        try body(mount)
    }
}

private func run(_ tool: String, _ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = arguments
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw POSIXError(.EIO) }
}

@Test func cloneOntoANonAPFSVolumeIsUnsupported() throws {
    try withTempDirectory { dir in
        let source = dir.appendingPathComponent("disk.img")
        try Data("data".utf8).write(to: source)
        try withFATVolume { fat in
            #expect(!CloneFile.volumeSupportsCloning(fat))
            #expect(throws: CloneError.unsupported) { try CloneFile.clone(source, to: fat.appendingPathComponent("disk.img")) }
        }
    }
}

@Test func apfsReportsPrivateSize() throws {
    try withTempDirectory { dir in
        try #require(CloneFile.volumeSupportsCloning(dir))
        let file = dir.appendingPathComponent("owned.img")
        try Data(repeating: 1, count: 2 << 20).write(to: file)
        let owned = try #require(DiskImage.privateBytes(file), "ATTR_CMNEXT_PRIVATESIZE unavailable")
        #expect(owned >= 2 << 20)
        let clone = dir.appendingPathComponent("clone.img")
        try CloneFile.clone(file, to: clone)
        #expect(try #require(DiskImage.privateBytes(clone)) < 1 << 20)
    }
}
