import CryptoKit
import Foundation
import Testing
import VMPaneCore

@testable import VMPaneHost

/// QEMU's tools from `qemu/scripts/package.sh` (build/qemu-bundle); import tests need them.
private let qemuImg = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("build/qemu-bundle/bin/qemu-img")
private let qemuImgBuilt = FileManager.default.isExecutableFile(atPath: qemuImg.path)

private func config(os: Int = 9, extra: String = "") -> String {
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <ParallelsVirtualMachine schemaVersion="1.0" dyn_lists="VirtualAppliance 0">
     <Identification><VmUuid>{0}</VmUuid><VmName>Ubuntu Desk</VmName></Identification>
     <Settings><General><OsType>\(os)</OsType><OsNumber>2301</OsNumber></General></Settings>
     <Hardware>
      <Cpu><Number>3</Number></Cpu>
      <Memory><RAM>4096</RAM></Memory>
      <Hdd dyn_lists="Partition 0" id="1"><Index>1</Index><Enabled>1</Enabled><EmulatedType>1</EmulatedType>
       <SystemName>data.hdd</SystemName></Hdd>
      <Hdd dyn_lists="Partition 0" id="0"><Index>0</Index><Enabled>1</Enabled><EmulatedType>1</EmulatedType>
       <SystemName>harddisk.hdd</SystemName><UserFriendlyName>harddisk.hdd</UserFriendlyName><Size>65536</Size>
       <Partition dyn_lists="" id="3"><SystemName>/dev/disk9s2</SystemName></Partition></Hdd>
      <Hdd dyn_lists="Partition 1" id="4"><Index>2</Index><Enabled>1</Enabled><EmulatedType>3</EmulatedType>
       <SystemName>Samsung SSD (disk1).hdd</SystemName></Hdd>
      \(extra)
     </Hardware>
    </ParallelsVirtualMachine>
    """
}

private func descriptor(image: String, type: String = "Compressed", sectors: UInt64, shots: Int = 1, storages: Int = 1) -> String {
    let storage = """
        <Storage><Start>0</Start><End>\(sectors)</End><Blocksize>2048</Blocksize>
         <Image><GUID>{5fbaabe3-6958-40ff-92a7-860e329aab41}</GUID><Type>\(type)</Type><File>\(image)</File></Image></Storage>
        """
    let shot =
        "<Shot><GUID>{5fbaabe3-6958-40ff-92a7-860e329aab41}</GUID><ParentGUID>{00000000-0000-0000-0000-000000000000}</ParentGUID></Shot>"
    return """
        <?xml version='1.0' encoding='UTF-8'?>
        <Parallels_disk_image Version="1.0">
         <Disk_Parameters><Disk_size>\(sectors)</Disk_size><Cylinders>1</Cylinders><Heads>16</Heads>
          <Sectors>32</Sectors><Padding>0</Padding></Disk_Parameters>
         <StorageData>\(String(repeating: storage, count: storages))</StorageData>
         <Snapshots>\(String(repeating: shot, count: shots))</Snapshots>
        </Parallels_disk_image>
        """
}

/// A `.pvm` with a boot disk (`harddisk.hdd`, image `image` written by `write`) and a second data disk.
private func makePVM(
    in root: URL, os: Int = 9, sectors: UInt64 = 131072, shots: Int = 1, storages: Int = 1, type: String = "Compressed",
    write: (URL) throws -> Void = { try Data(count: 512).write(to: $0) }
) throws -> URL {
    let pvm = root.appendingPathComponent("Ubuntu Desk.pvm")
    for name in ["harddisk.hdd", "data.hdd"] {
        let hdd = pvm.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: hdd, withIntermediateDirectories: true)
        let image = "\(name).0.{5fbaabe3-6958-40ff-92a7-860e329aab41}.hds"
        try write(hdd.appendingPathComponent(image))
        try descriptor(image: image, type: type, sectors: sectors, shots: shots, storages: storages)
            .write(to: hdd.appendingPathComponent("DiskDescriptor.xml"), atomically: true, encoding: .utf8)
    }
    try config(os: os).write(to: pvm.appendingPathComponent("config.pvs"), atomically: true, encoding: .utf8)
    return pvm
}

private func temporary() throws -> URL {
    let root = URL(fileURLWithPath: "/tmp/vp-pvm-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

@Test func parallelsSettingsAreRead() throws {
    let root = try temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    let pvm = try makePVM(in: root)
    let vm = try ParallelsVM.read(pvm)
    #expect(vm.name == "Ubuntu Desk" && vm.os == .linux && vm.cpuCount == 3 && vm.memoryMiB == 4096)
    #expect(vm.disks.map(\.lastPathComponent) == ["harddisk.hdd", "data.hdd"], "boot disk first; the physical disk is left out")
    let disk = try ParallelsDisk.read(vm.disks[0])
    #expect(disk.format == .expanding && disk.sizeBytes == 131072 * 512)
    #expect(disk.image.lastPathComponent.hasPrefix("harddisk.hdd.0."))
}

@Test func unsupportedParallelsVMsAreRefusedClearly() throws {
    let root = try temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(throws: PVMImportError.macOSGuest) { try ParallelsVM.read(try makePVM(in: root.appendingPathComponent("m"), os: 7)) }
    let withSnapshots = try makePVM(in: root.appendingPathComponent("s"), shots: 2)
    #expect(throws: PVMImportError.snapshots) { try ParallelsDisk.read(withSnapshots.appendingPathComponent("harddisk.hdd")) }
    let split = try makePVM(in: root.appendingPathComponent("p"), storages: 2)
    #expect(throws: PVMImportError.splitDisk) { try ParallelsDisk.read(split.appendingPathComponent("harddisk.hdd")) }
    let external = root.appendingPathComponent("x.pvm")
    try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
    try #"<!DOCTYPE x [<!ENTITY e SYSTEM "file:///etc/passwd">]><ParallelsVirtualMachine><VmName>&e;</VmName></ParallelsVirtualMachine>"#
        .write(to: external.appendingPathComponent("config.pvs"), atomically: true, encoding: .utf8)
    #expect(throws: PVMImportError.self) { try ParallelsVM.read(external) }  // no disk; the entity is never loaded
    #expect(ParallelsImporter.lastPercent("    (0.00/100%)\r    (37.50/100%)\r") == 37.5)
    // An untrusted .pvm cannot point at files outside itself.
    let escaping = try makePVM(in: root.appendingPathComponent("e"))
    try descriptor(image: "../../../../../etc/hosts", sectors: 8)
        .write(to: escaping.appendingPathComponent("harddisk.hdd/DiskDescriptor.xml"), atomically: true, encoding: .utf8)
    #expect(throws: PVMImportError.self) { try ParallelsDisk.read(escaping.appendingPathComponent("harddisk.hdd")) }
    try descriptor(image: "/etc/hosts", sectors: 8)
        .write(to: escaping.appendingPathComponent("harddisk.hdd/DiskDescriptor.xml"), atomically: true, encoding: .utf8)
    #expect(throws: PVMImportError.self) { try ParallelsDisk.read(escaping.appendingPathComponent("harddisk.hdd")) }
}

/// The whole import with QEMU's qemu-img: an expanding Parallels image converts to the same bytes, the VM gets the
/// Parallels CPUs and memory, and the .pvm is untouched.
@Test(.enabled(if: qemuImgBuilt, "build the QEMU bundle: qemu/scripts/package.sh"))
func parallelsDisksConvertToTheSameBytes() async throws {
    let root = try temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    var raw = Data(count: 64 << 20)
    for offset in stride(from: 0, to: raw.count, by: 3 << 20) {
        raw.replaceSubrange(offset..<offset + 4096, with: (0..<4096).map { _ in UInt8.random(in: 0...255) })
    }
    let source = root.appendingPathComponent("source.raw")
    try raw.write(to: source)
    let pvm = try makePVM(in: root, sectors: UInt64(raw.count / 512)) { image in
        let convert = Process()
        convert.executableURL = qemuImg
        convert.arguments = ["convert", "-f", "raw", "-O", "parallels", source.path, image.path]
        try convert.run()
        convert.waitUntilExit()
        #expect(convert.terminationStatus == 0)
    }
    let hds = try ParallelsDisk.read(pvm.appendingPathComponent("harddisk.hdd")).image
    let before = SHA256.hash(data: try Data(contentsOf: hds))
    let library = VMLibrary(paths: VMPanePaths(root: root.appendingPathComponent("s")))
    let ops = LibraryOps(library: library, identity: .ui)
    let progress = Progress()
    let bundle = try await ParallelsImporter(qemuImg: qemuImg).importVM(pvm, name: "Imported", os: .linux, ops: ops) { value in
        progress.completedUnitCount = Int64(value * 100)
    }
    let config = try ConfigStore.load(bundle)
    #expect(config.os == .linux && config.cpu.count == min(3, ProcessInfo.processInfo.activeProcessorCount) && config.memory.mib == 4096)
    let disk = try bundle.fileURL(relativePath: config.disks[0].file)
    let handle = try FileHandle(forReadingFrom: disk)
    let converted = try handle.read(upToCount: raw.count)
    let size = try handle.seekToEnd()
    try handle.close()
    #expect(converted == raw)
    #expect(size == 1 << 30, "rounded up to the whole GiB the config states")
    #expect(SHA256.hash(data: try Data(contentsOf: hds)) == before, "the .pvm is only read")
    #expect(progress.completedUnitCount == 100)
}
