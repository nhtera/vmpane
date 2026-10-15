import AppKit
import VMPaneCore

/// A VM about to start while the Mac has less memory available than the VM may use.
public struct LowMemoryStart: Equatable, Sendable {
    public var name: String
    public var guestBytes: UInt64
    public var availableBytes: UInt64

    public static let title = "Your Mac is low on memory"

    public var message: String {
        "“\(name)” can use \(HostMemory.describe(guestBytes)) of memory, but only \(HostMemory.describe(availableBytes)) "
            + "is available on this Mac. A VM started now may run slowly or crash. Quit apps you don’t need first, "
            + "or start it anyway."
    }
}

/// Asks before a VM starts on a Mac that is low on memory; the VM starts at once when there is room.
@MainActor
public struct LowMemoryGuard {
    public var memory: @Sendable () -> HostMemory?
    /// Whether to start anyway.
    public var confirm: @MainActor (LowMemoryStart) async -> Bool

    public init(
        memory: @escaping @Sendable () -> HostMemory? = { HostMemory.current() },
        confirm: @escaping @MainActor (LowMemoryStart) async -> Bool
    ) {
        self.memory = memory
        self.confirm = confirm
    }

    /// Whether VM `name`, with `guestMiB` of memory, should start now.
    func allows(name: String, guestMiB: Int) async -> Bool {
        let guestBytes = UInt64(max(0, guestMiB)) << 20
        guard let host = memory(), host.tooLow(forGuest: guestBytes) else { return true }
        return await confirm(LowMemoryStart(name: name, guestBytes: guestBytes, availableBytes: host.availableBytes))
    }

    /// The apps' guard: an alert, as a sheet on the window `window` gives, else on its own.
    public static func alert(window: @escaping @MainActor () -> NSWindow? = { nil }) -> LowMemoryGuard {
        LowMemoryGuard { start in
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = LowMemoryStart.title
            alert.informativeText = start.message
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Start Anyway")
            guard let window = window() else { return alert.runModal() == .alertSecondButtonReturn }
            return await withCheckedContinuation { done in
                alert.beginSheetModal(for: window) { done.resume(returning: $0 == .alertSecondButtonReturn) }
            }
        }
    }
}
