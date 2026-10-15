import Darwin
import Foundation

/// How much memory this Mac has to spare now. A VM's memory comes out of the Mac's: on a Mac out of memory (free
/// memory gone, swap nearly full) Linux guests crashed with memory that changed under them, and the same VMs ran
/// cleanly once memory was free again (macOS 15.7, 2026-10).
public struct HostMemory: Equatable, Sendable {
    /// Memory macOS can hand out without compressing or swapping: free pages, cached files and purgeable memory.
    /// (Inactive app memory is not: it must be compressed or swapped first, which is what runs out.)
    public var availableBytes: UInt64
    /// The Mac's RAM.
    public var physicalBytes: UInt64

    public init(availableBytes: UInt64, physicalBytes: UInt64) {
        self.availableBytes = availableBytes
        self.physicalBytes = physicalBytes
    }

    /// The Mac's memory now; nil when macOS does not say.
    public static func current() -> HostMemory? {
        // Tests show the warnings on any Mac: the available MiB, read from the file this names at each call.
        if let file = ProcessInfo.processInfo.environment["VMPANE_TEST_AVAILABLE_MIB_FILE"],
            let text = try? String(contentsOfFile: file, encoding: .utf8),
            let mib = UInt64(text.trimmingCharacters(in: .whitespacesAndNewlines))
        {
            return HostMemory(availableBytes: mib << 20, physicalBytes: ProcessInfo.processInfo.physicalMemory)
        }
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        // free_count includes the speculative pages (vm_stat lists them apart); external pages back files.
        let pages = UInt64(stats.free_count) + UInt64(stats.external_page_count) + UInt64(stats.purgeable_count)
        return HostMemory(availableBytes: pages * UInt64(getpagesize()), physicalBytes: ProcessInfo.processInfo.physicalMemory)
    }

    /// Less is available than a VM with `guestBytes` of memory may use: macOS would have to compress or swap it.
    public func tooLow(forGuest guestBytes: UInt64) -> Bool { availableBytes < guestBytes }

    /// Almost nothing left: under 1 GB or 3 % of the Mac's memory, whichever is more.
    public var nearlyOut: Bool { availableBytes < reserve }

    /// Room again after `nearlyOut`: twice that, so a warning does not come and go at the edge.
    public var recovered: Bool { availableBytes >= 2 * reserve }

    private var reserve: UInt64 { max(1 << 30, physicalBytes * 3 / 100) }

    /// "1.2 GB": memory sizes the way Activity Monitor writes them.
    public static func describe(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .memory)
    }
}
