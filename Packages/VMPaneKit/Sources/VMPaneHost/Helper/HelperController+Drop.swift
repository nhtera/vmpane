import Foundation
import VMPaneControl
import VMPaneCore

/// `vm.files.drop`: files and folders from the Mac (dropped on the VM window) copied into the guest, into a new
/// folder in the logged-in user's `Desktop/VMPane Drops`, owned by that user, then shown in their file manager.
/// Folders are copied recursively (not archived); symlinks are skipped and reported. Progress goes out as
/// `files.progress` on the `files` topic.
extension HelperController {
    private struct DropParams: Decodable { var paths: [String] }

    /// One thing to create in the guest: a folder, or a file and where it comes from.
    struct DropItem: Equatable {
        /// Relative to the drop folder, "/"-separated.
        let path: String
        let source: URL?
        let size: UInt64
    }

    func dropFiles(_ params: JSONValue?) async -> Result<JSONValue, RPCError> {
        let paths: [String]
        switch RPCParams.decode(DropParams.self, from: params) {
        case .success(let decoded): paths = decoded.paths
        case .failure(let error): return .failure(error)
        }
        guard !paths.isEmpty, paths.allSatisfy({ $0.hasPrefix("/") }) else {
            return .failure(RPCError(.invalidParams, "paths must be absolute host paths"))
        }
        guard let connection = await agentHub.waitForConnection(timeout: Self.agentWait), let peer = await agentHub.status.peer else {
            return .failure(RPCError(.agentUnavailable, "the guest agent is not connected"))
        }
        var dropFolder: String?
        do {
            let (items, skipped) = try await Blocking.run { try Self.dropItems(paths.map { URL(fileURLWithPath: $0) }) }
            let windows = peer.hello.os == "windows"
            let folder = try await makeDropFolder(items.filter { $0.source == nil }.map(\.path), windows: windows, on: connection)
            dropFolder = folder.path
            let done = try await pushItems(items, into: folder.path, windows: windows, on: connection)
            if let owner = folder.owner {
                // The agent wrote as root: the files become the user's.
                let chown = try await agentExecs.run(
                    AgentExecStartParams(argv: ["chown", "-R", owner, folder.path], as: .admin, timeoutMs: 60000), on: connection)
                if chown.exited?.code != 0 { throw RPCError(.internalError, "cannot give the dropped files to the guest's user") }
            }
            let reveal = try? await connection.call(AgentMethod.sessionReveal, ["path": .string(folder.path)], timeout: .seconds(10))
            let files = items.filter { $0.source != nil }.count
            return .success([
                "guestPath": .string(folder.path), "files": .int(Int64(files)), "bytes": .int(Int64(done)),
                "skipped": .array(skipped.map { .string($0) }), "revealed": .bool(reveal != nil),
            ])
        } catch is CancellationError {
            if let folder = dropFolder {
                // Not cancelled itself: the removal must still reach the guest.
                let windows = peer.hello.os == "windows"
                await Task { await self.removeDropFolder(folder, windows: windows, on: connection) }.value
            }
            return .failure(RPCError(.invalidState, "cancelled"))
        } catch let error as RPCError {
            return .failure(error)
        } catch let error as AgentConnection.ConnectionError {
            if case .rpc(let agentError) = error { return .failure(agentError) }
            return .failure(RPCError(.agentUnavailable, error.description))
        } catch {
            return .failure(RPCError(.internalError, ErrorText.readable(error)))
        }
    }

    /// Copies the drop's files into `folder`, announcing progress; throws `CancellationError` once cancelled.
    private func pushItems(_ items: [DropItem], into folder: String, windows: Bool, on connection: AgentConnection) async throws -> UInt64 {
        let total = items.reduce(0) { $0 + $1.size }
        var done: UInt64 = 0
        for item in items {
            guard !Task.isCancelled else { throw CancellationError() }
            guard let source = item.source else { continue }
            let target = folder + (windows ? "\\" + item.path.replacingOccurrences(of: "/", with: "\\") : "/" + item.path)
            let before = done
            let server = server
            do {
                done += try await Self.push(FileTransfer(hostPath: source.path, guestPath: target), on: connection) { sent in
                    server?.broadcast(
                        topic: "files", method: ControlNotification.filesProgress.rawValue,
                        params: ["bytesDone": .int(Int64(before + sent)), "bytesTotal": .int(Int64(total)), "file": .string(item.path)])
                }
            } catch  where Task.isCancelled {
                throw CancellationError()
            }
        }
        return done
    }

    /// A cancelled drop's folder goes away again (as the user, who made it).
    private func removeDropFolder(_ path: String, windows: Bool, on connection: AgentConnection) async {
        let argv =
            windows
            ? ["cmd.exe", "/c", "rmdir", "/s", "/q", path]
            : ["/bin/rm", "-rf", "--", path]
        // As the user: their folder, so they may remove what root wrote into it, and nothing else.
        _ = try? await agentExecs.run(AgentExecStartParams(argv: argv, as: .user, timeoutMs: 60000), on: connection)
    }

    /// What `urls` expand to: each top-level item by its name, folders walked; symlinks are skipped (their names
    /// returned). Folders come before their contents. Names are NFC: macOS hands out decomposed names, other
    /// systems expect composed ones.
    static func dropItems(_ urls: [URL]) throws -> (items: [DropItem], skipped: [String]) {
        var items: [DropItem] = []
        var skipped: [String] = []
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey]
        func visit(_ url: URL, as path: String) throws {
            let values = try url.resourceValues(forKeys: Set(keys))
            if values.isSymbolicLink == true {
                skipped.append(path)
            } else if values.isDirectory == true {
                items.append(DropItem(path: path, source: nil, size: 0))
                let children = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys)
                for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                    try visit(child, as: path + "/" + child.lastPathComponent.precomposedStringWithCanonicalMapping)
                }
            } else if values.isRegularFile == true {
                items.append(DropItem(path: path, source: url, size: UInt64(values.fileSize ?? 0)))
            } else {
                skipped.append(path)
            }
        }
        for url in urls { try visit(url, as: url.lastPathComponent.precomposedStringWithCanonicalMapping) }
        return (items, skipped)
    }

    /// Creates the drop folder (and `folders` in it) as the logged-in user; returns its path and, on Unix guests,
    /// the user's `uid:gid`. Names travel as arguments (Unix) or base64 (PowerShell), never inside the script.
    private func makeDropFolder(_ folders: [String], windows: Bool, on connection: AgentConnection) async throws
        -> (path: String, owner: String?)
    {
        let params: AgentExecStartParams
        if windows {
            let names = (try? JSONEncoder().encode(folders))?.base64EncodedString() ?? "W10="
            let script = """
                $d = Join-Path ([Environment]::GetFolderPath('Desktop')) ('VMPane Drops\\' + (Get-Date -Format 'yyyy-MM-dd HH.mm.ss'))
                New-Item -ItemType Directory -Force -Path $d | Out-Null
                foreach ($n in ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('\(names)')) | ConvertFrom-Json)) {
                  New-Item -ItemType Directory -Force -Path (Join-Path $d $n) | Out-Null }
                Write-Output $d
                """
            params = AgentExecStartParams(
                argv: ["powershell.exe", "-NoProfile", "-NonInteractive", "-Command", script], as: .user, timeoutMs: 30000)
        } else {
            let script = """
                d="$HOME/Desktop/VMPane Drops/$(/bin/date '+%Y-%m-%d %H.%M.%S')"
                /bin/mkdir -p "$d" || exit 1
                for f in "$@"; do /bin/mkdir -p "$d/$f" || exit 1; done
                printf '%s\\n%s:%s\\n' "$d" "$(/usr/bin/id -u)" "$(/usr/bin/id -g)"
                """
            params = AgentExecStartParams(argv: ["/bin/sh", "-c", script, "sh"] + folders, as: .user, timeoutMs: 30000)
        }
        let made = try await agentExecs.run(params, on: connection)
        let lines = (String(bytes: made.stdout, encoding: .utf8) ?? "").split(whereSeparator: \.isNewline).map(String.init)
        // The path comes from the guest user's shell and steers a root chown: it must be a drop folder.
        guard made.exited?.code == 0, let path = lines.first, Self.isDropFolder(path, windows: windows) else {
            let reason = String(bytes: made.stderr, encoding: .utf8) ?? ""
            throw RPCError(.agentUnavailable, "cannot make the drop folder in the guest (is someone logged in?) \(reason)")
        }
        let owner = lines.dropFirst().first
        guard windows || owner.map(Self.isNumericOwner) == true else {
            throw RPCError(.internalError, "the guest named an odd owner for the drop folder")
        }
        return (path, windows ? nil : owner)
    }

    /// `…/Desktop/VMPane Drops/<time>`, absolute, no `..` (what the drop script makes; anything else is refused).
    static func isDropFolder(_ path: String, windows: Bool) -> Bool {
        let separator: Character = windows ? "\\" : "/"
        let parts = path.split(separator: separator, omittingEmptySubsequences: false)
        let absolute = windows ? path.dropFirst().hasPrefix(":\\") : path.hasPrefix("/")
        return absolute && parts.count >= 4 && !parts.contains("..") && !parts.contains(".")
            && parts[parts.count - 3] == "Desktop" && parts[parts.count - 2] == "VMPane Drops" && !parts[parts.count - 1].isEmpty
    }

    /// `uid:gid`, digits only.
    static func isNumericOwner(_ owner: String) -> Bool {
        let ids = owner.split(separator: ":", omittingEmptySubsequences: false)
        return ids.count == 2 && ids.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
    }
}
