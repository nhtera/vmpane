import Foundation
import MetricKit
import VMPaneCore

/// On-device crash, hang and exception reports from MetricKit, kept in VMPane's folder (`diagnostics/`) for
/// `vmpane doctor --diagnostics`. VMPane sends nothing over the network (no crash-reporting service); a person
/// attaches the zip to an issue if they choose. The app and each helper subscribe.
public final class CrashReports: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    public static let kept = 20
    let folder: URL
    let process: String

    /// `process` names the files ("app", "helper").
    public init(paths: VMPanePaths, process: String) {
        folder = Self.folder(paths)
        self.process = process
    }

    public static func folder(_ paths: VMPanePaths) -> URL { paths.root.appendingPathComponent("diagnostics", isDirectory: true) }

    /// A collector for `process`, subscribed.
    public static func start(paths: VMPanePaths, process: String) -> CrashReports {
        let reports = CrashReports(paths: paths, process: process)
        reports.start()
        return reports
    }

    public func start() {
        MXMetricManager.shared.add(self)
        record(MXMetricManager.shared.pastDiagnosticPayloads)
    }

    public func didReceive(_ payloads: [MXDiagnosticPayload]) { record(payloads) }

    private func record(_ payloads: [MXDiagnosticPayload]) {
        guard !payloads.isEmpty else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for payload in payloads {
            let stamp = Int(payload.timeStampEnd.timeIntervalSince1970)
            let file = folder.appendingPathComponent("\(process)-\(stamp)-\(UUID().uuidString.prefix(8)).json")
            fm.createFile(atPath: file.path, contents: payload.jsonRepresentation(), attributes: [.posixPermissions: 0o600])
        }
        // The newest few are enough to see a pattern.
        let all = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let dated = all.map {
            ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast)
        }
        for (old, _) in dated.sorted(by: { $0.1 > $1.1 }).dropFirst(Self.kept) { try? fm.removeItem(at: old) }
    }
}
