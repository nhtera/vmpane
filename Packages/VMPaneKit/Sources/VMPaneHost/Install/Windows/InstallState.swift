import Foundation
import VMPaneCore

/// `install/install.json`: where an unattended Windows install is, written at every step (durably, under the
/// bundle lock) so a helper that crashed, an app update or a Mac restart resumes it instead of starting over
/// (Red Team #14).
public struct InstallState: Codable, Equatable, Sendable {
    public static let schemaVersion = 1
    public static let fileName = "install.json"

    public enum Phase: String, Codable, Sendable, CaseIterable {
        /// Media and unattend image ready; the VM has not started yet.
        case prepared
        /// First boot from the Windows ISO: "Press any key to boot from CD" gets key presses (only now, a few
        /// seconds).
        case firstBoot
        /// Setup copies Windows to the disk, reboots (the ISO is ejected at the first reboot), specializes and runs
        /// OOBE.
        case setupRunning
        /// The installed Windows reached its first logon (install.ps1 reported in).
        case firstLogon
        /// Drivers and tools are installed; the VM shuts down for finalize.
        case toolsInstalled
        /// Install media removed; the VM restarts with its network and virtio display.
        case done
        case failed
        case cancelled
    }

    public var schemaVersion: Int
    public var phase: Phase
    public var startedAt: Date
    /// When `phase` was entered (timeouts count from here).
    public var phaseStartedAt: Date
    /// Boots from the ISO tried so far ("press any key" missed: the firmware fell to its shell).
    public var attempts: Int
    /// The Windows ISO was ejected after Setup's first reboot (so Setup can never start over and wipe the disk).
    public var mediaEjected: Bool
    /// Why the install failed or was cancelled.
    public var reason: String?

    public init(now: Date = Date()) {
        schemaVersion = Self.schemaVersion
        phase = .prepared
        startedAt = now
        phaseStartedAt = now
        attempts = 0
        mediaEjected = false
        reason = nil
    }

    public var isFinished: Bool { [.done, .failed, .cancelled].contains(phase) }

    /// The phases an install moves through in order.
    static let order: [Phase] = [.prepared, .firstBoot, .setupRunning, .firstLogon, .toolsInstalled, .done]

    /// How long a phase may last before the install is declared failed (the S1 install took ≈ 43 min in all).
    public static let timeouts: [Phase: TimeInterval] = [
        .firstBoot: 3 * 60, .setupRunning: 90 * 60, .firstLogon: 30 * 60, .toolsInstalled: 15 * 60,
    ]

    /// Moves forward to `next` (never back, never out of a finished install).
    public mutating func advance(to next: Phase, now: Date = Date()) {
        guard !isFinished, let from = Self.order.firstIndex(of: phase), let to = Self.order.firstIndex(of: next), to > from else { return }
        phase = next
        phaseStartedAt = now
        if next == .firstBoot { attempts += 1 }
    }

    /// Ends the install unsuccessfully (failed or cancelled), keeping the first reason.
    public mutating func end(_ phase: Phase, reason: String, now: Date = Date()) {
        guard !isFinished, phase == .failed || phase == .cancelled else { return }
        self.phase = phase
        self.reason = reason
        phaseStartedAt = now
    }

    /// The phase that ran out of time at `now`, if any.
    public func timedOut(now: Date = Date()) -> Bool {
        guard let limit = Self.timeouts[phase] else { return false }
        return now.timeIntervalSince(phaseStartedAt) > limit
    }

    // MARK: - Persistence

    public static func url(in bundle: VMBundle) -> URL { bundle.installDirectory.appendingPathComponent(fileName) }

    /// The persisted state, or nil when there is none (or it was written by a newer VMPane).
    public static func load(from bundle: VMBundle) -> InstallState? {
        guard let data = try? Data(contentsOf: url(in: bundle)),
            let state = try? CanonicalJSON.decoder().decode(InstallState.self, from: data),
            state.schemaVersion <= schemaVersion
        else { return nil }
        return state
    }

    public func save(holding lock: BundleLock) throws {
        try FileManager.default.createDirectory(
            at: lock.bundle.installDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try DurableWrite.write(CanonicalJSON.encode(self), to: Self.url(in: lock.bundle))
    }

    public static func remove(from bundle: VMBundle) {
        try? FileManager.default.removeItem(at: url(in: bundle))
    }
}
