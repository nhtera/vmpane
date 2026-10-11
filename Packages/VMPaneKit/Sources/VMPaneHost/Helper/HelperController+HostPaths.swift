import Foundation
import VMPaneControl
import VMPaneCore

/// Host paths that a client other than the app names for file copies (`agent.file.push/pull`, `vm.files.drop`)
/// stay out of VMPane's own files: its folder (the policy key, the kill switch, run files) and every VM bundle
/// (configs with their policy tags, disks, saved memory). Paths are compared after resolving links.
extension HelperController {
    func hostPathRefusal(_ request: RPCRequest) -> RPCError? {
        let paths: [String]
        switch ControlMethod(rawValue: request.method) {
        case .agentFilePush?, .agentFilePull?: paths = [request.params?["hostPath"]?.stringValue].compactMap { $0 }
        case .vmFilesDrop?:
            guard case .array(let items)? = request.params?["paths"] else { return nil }
            paths = items.compactMap(\.stringValue)
        default: return nil
        }
        let protected = protectedHostFolders()
        for path in paths where path.hasPrefix("/") {
            let resolved = Self.resolvedComponents(path)
            if protected.contains(where: { resolved.starts(with: $0) }) {
                return RPCError(.policyDenied, "\(path) is inside VMPane's own files; only the app may copy there")
            }
        }
        return nil
    }

    private func protectedHostFolders() -> [[String]] {
        let support = prepared.runFiles.paths
        var folders = [support.root.path]
        folders += ((try? VMLibrary(paths: support).items()) ?? []).map(\.bundle.url.path)
        folders.append(prepared.lock.bundle.url.path)
        return folders.map(Self.resolvedComponents)
    }

    /// `path`'s components with links resolved as far as it exists (the rest as given, `..` folded).
    static func resolvedComponents(_ path: String) -> [String] {
        var existing = URL(fileURLWithPath: path).standardizedFileURL
        var rest: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path), existing.path != "/" {
            rest.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }
        let real = existing.path.withCString { pointer -> String in
            guard let resolved = realpath(pointer, nil) else { return existing.path }
            defer { free(resolved) }
            return String(cString: resolved)
        }
        return (real.split(separator: "/").map(String.init) + rest).map { $0.precomposedStringWithCanonicalMapping.lowercased() }
    }
}
