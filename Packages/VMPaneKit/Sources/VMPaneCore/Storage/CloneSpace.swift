import Darwin
import Foundation

/// Space held by APFS clones. A snapshot's disks are clones of the live set: at first they share every block
/// with it, and they take space of their own only as the live disks change. The allocated size of a clone
/// counts the shared blocks too, so it says nothing about what removing the clone gives back.
public enum CloneSpace {
    /// Bytes of `url` that no other file shares (what removing it frees); for a directory, the sum over the
    /// files in it. Nil when the file system does not say (not APFS).
    public static func privateBytes(_ url: URL) -> UInt64? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return nil }
        guard isDirectory.boolValue else { return filePrivateBytes(url.path) }
        guard let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey]) else { return nil }
        var total: UInt64 = 0
        for case let file as URL in files where (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            guard let bytes = filePrivateBytes(file.path) else { return nil }
            total += bytes
        }
        return total
    }

    /// `ATTR_CMNEXT_PRIVATESIZE`: the file's bytes not shared with a clone.
    private static func filePrivateBytes(_ path: String) -> UInt64? {
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS)
        request.forkattr = attrgroup_t(ATTR_CMNEXT_PRIVATESIZE)
        // Reply: UInt32 length, the returned attribute set, then the off_t.
        var reply = [UInt8](repeating: 0, count: 4 + MemoryLayout<attribute_set_t>.size + MemoryLayout<off_t>.size)
        guard getattrlist(path, &request, &reply, reply.count, UInt32(FSOPT_ATTR_CMN_EXTENDED | FSOPT_NOFOLLOW)) == 0 else {
            return nil
        }
        return reply.withUnsafeBytes { raw in
            let returned = raw.loadUnaligned(fromByteOffset: 4, as: attribute_set_t.self)
            guard returned.forkattr & attrgroup_t(ATTR_CMNEXT_PRIVATESIZE) != 0 else { return nil }
            let bytes = raw.loadUnaligned(fromByteOffset: 4 + MemoryLayout<attribute_set_t>.size, as: off_t.self)
            return UInt64(max(bytes, 0))
        }
    }
}
