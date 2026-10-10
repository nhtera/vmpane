import Foundation

/// The browser-assisted ISO source: the user downloads Windows from Microsoft's page in their own browser, and
/// this notices the finished ISO in the downloads folder. Browsers write to a partial name (Safari `.download`,
/// Chrome `.crdownload`, Firefox `.part`) and rename at the end, so a candidate is a Windows Arm64 ISO name
/// that was not there when watching began, whose size stayed the same over `stableChecks` polls. The file is
/// only a candidate: `WindowsISOInspector` decides whether it is usable.
public struct DownloadWatcher: Sendable {
    public var directory: URL
    public var interval: Duration
    public var stableChecks: Int

    public init(directory: URL, interval: Duration = .seconds(2), stableChecks: Int = 2) {
        self.directory = directory
        self.interval = interval
        self.stableChecks = stableChecks
    }

    /// `~/Downloads`.
    public static var userDownloads: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)
    }

    /// Microsoft names its media `Win11_<release>_<Language>_Arm64.iso`; other channels `Windows11_…arm64….iso`.
    static func isCandidateName(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.hasPrefix("win") && lower.contains("arm64") && lower.hasSuffix(".iso")
    }

    /// The ISOs present now (they are never reported: the user picks an existing file from disk instead).
    public func snapshot() -> Set<String> {
        Set(currentSizes().keys)
    }

    /// Waits for a new, complete candidate (or cancellation, which returns nil).
    public func waitForDownload(ignoring existing: Set<String>) async -> URL? {
        var sizes: [String: (size: UInt64, unchanged: Int)] = [:]
        while !Task.isCancelled {
            for (name, size) in currentSizes() where !existing.contains(name) {
                let seen = sizes[name]
                let unchanged = seen?.size == size ? (seen?.unchanged ?? 0) + 1 : 0
                sizes[name] = (size, unchanged)
                if unchanged >= stableChecks, size > 0 { return directory.appendingPathComponent(name) }
            }
            try? await Task.sleep(for: interval)
        }
        return nil
    }

    private func currentSizes() -> [String: UInt64] {
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey]
        let entries = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)) ?? []
        var sizes: [String: UInt64] = [:]
        for entry in entries where Self.isCandidateName(entry.lastPathComponent) {
            guard let values = try? entry.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            sizes[entry.lastPathComponent] = UInt64(values.fileSize ?? 0)
        }
        return sizes
    }
}
