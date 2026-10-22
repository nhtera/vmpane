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

    func dropFiles(_ params: JSONValue?, from owner: ControlConnection? = nil) async -> Result<JSONValue, RPCError> {
        let paths: [String]
        switch RPCParams.decode(DropParams.self, from: params) {
        case .success(let decoded): paths = decoded.paths
        case .failure(let error): return .failure(error)
        }
        guard !paths.isEmpty, paths.allSatisfy({ $0.hasPrefix("/") }) else {
            return .failure(RPCError(.invalidParams, "paths must be absolute host paths"))
        }
        let admitted = agentGeneration
        guard let connection = await agentHub.waitForConnection(timeout: Self.agentWait), let peer = await agentHub.status.peer else {
            return .failure(RPCError(.agentUnavailable, "the guest agent is not connected"))
        }
        var dropFolder: String?
        do {
            try checkStillAdmitted(since: admitted, owner, .vmFilesDrop)
            let copied = try await copyIntoGuest(
                paths.map { URL(fileURLWithPath: $0) }, place: .drop, windows: peer.hello.os == "windows", on: connection
            ) { dropFolder = $0 }
            let reveal = try? await connection.call(AgentMethod.sessionReveal, ["path": .string(copied.folder)], timeout: .seconds(10))
            return .success([
                "guestPath": .string(copied.folder), "files": .int(Int64(copied.files)), "bytes": .int(Int64(copied.bytes)),
                "skipped": .array(copied.skipped.map { .string($0) }), "revealed": .bool(reveal != nil),
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

    /// Where files from the Mac go in the guest: a drop on the window (shown to the user), or files copied on the
    /// Mac waiting to be pasted in the guest (out of sight, each copy replacing the one before).
    enum GuestFolderPlace {
        case drop, clipboard

        /// The two folders above each made one (what `isGuestFolder` checks).
        func parents(windows: Bool) -> (String, String) {
            switch self {
            case .drop: ("Desktop", "VMPane Drops")
            case .clipboard: (windows ? "Temp" : "Caches", "VMPane Clipboard")
            }
        }
    }

    /// What `copyIntoGuest` did: the folder it made, the top-level items' guest paths, and the counts.
    struct GuestCopy {
        let folder: String
        let top: [String]
        let files: Int
        let bytes: UInt64
        let skipped: [String]
    }

    /// Copies host files and folders (`urls`) into a new folder at `place` in the guest, owned by its user, with
    /// progress on the `files` topic for a drop. `made` learns the folder once it exists (to remove a cancelled
    /// drop's). At most `maxFiles` files and `maxBytes` bytes, checked before anything is made.
    func copyIntoGuest(
        _ urls: [URL], place: GuestFolderPlace, windows: Bool, maxFiles: Int = .max, maxBytes: UInt64 = .max,
        on connection: AgentConnection, made: (String) -> Void = { _ in }
    ) async throws -> GuestCopy {
        let (items, skipped) = try await Blocking.run { try Self.dropItems(urls) }
        let files = items.filter { $0.source != nil }
        let total = files.reduce(0) { $0 + $1.size }
        guard files.count <= maxFiles, total <= maxBytes else {
            throw RPCError(.invalidParams, "\(files.count) files, \(total >> 20) MiB: more than the clipboard carries")
        }
        let folder = try await makeGuestFolder(place, items.filter { $0.source == nil }.map(\.path), windows: windows, on: connection)
        made(folder.path)
        let done = try await pushItems(items, into: folder.path, windows: windows, progress: place == .drop, on: connection)
        if let owner = folder.owner {
            // The agent wrote as root: the files become the user's.
            let chown = try await agentExecs.run(
                AgentExecStartParams(argv: ["chown", "-R", owner, folder.path], as: .admin, timeoutMs: 60000), on: connection)
            if chown.exited?.code != 0 { throw RPCError(.internalError, "cannot give the copied files to the guest's user") }
        }
        let separator = windows ? "\\" : "/"
        let top = items.filter { !$0.path.contains("/") }.map { folder.path + separator + $0.path }
        return GuestCopy(folder: folder.path, top: top, files: files.count, bytes: done, skipped: skipped)
    }

    /// Files copied on the Mac, put in the guest for its clipboard: their guest paths (HostFileSink's budget).
    func stageClipboardFiles(_ paths: [String], on connection: AgentConnection) async throws -> [String] {
        guard let peer = await agentHub.status.peer else { throw RPCError(.agentUnavailable, "the guest agent is not connected") }
        return try await copyIntoGuest(
            paths.map { URL(fileURLWithPath: $0) }, place: .clipboard, windows: peer.hello.os == "windows",
            maxFiles: HostFileSink.defaultMaxFiles, maxBytes: UInt64(HostFileSink.defaultMaxBytes), on: connection
        ).top
    }

    /// Copies the items' files into `folder`, announcing progress if asked; throws `CancellationError` once cancelled.
    private func pushItems(_ items: [DropItem], into folder: String, windows: Bool, progress: Bool, on connection: AgentConnection)
        async throws -> UInt64
    {
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
                    guard progress else { return }
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

    /// Creates a new folder at `place` (and `folders` in it) as the logged-in user; returns its path and, on Unix
    /// guests, the user's `uid:gid`. The clipboard's replaces the one before. Names travel as arguments (Unix) or
    /// base64 (PowerShell), never inside the script.
    private func makeGuestFolder(_ place: GuestFolderPlace, _ folders: [String], windows: Bool, on connection: AgentConnection)
        async throws -> (path: String, owner: String?)
    {
        let params: AgentExecStartParams
        if windows {
            let names = (try? JSONEncoder().encode(folders))?.base64EncodedString() ?? "W10="
            let root =
                switch place {
                case .drop: "$r = Join-Path ([Environment]::GetFolderPath('Desktop')) 'VMPane Drops'"
                case .clipboard:
                    """
                    $r = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Temp\\VMPane Clipboard'
                    Remove-Item -LiteralPath $r -Recurse -Force -ErrorAction SilentlyContinue
                    """
                }
            let script = """
                \(root)
                $d = Join-Path $r (Get-Date -Format 'yyyy-MM-dd HH.mm.ss')
                New-Item -ItemType Directory -Force -Path $d | Out-Null
                foreach ($n in ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('\(names)')) | ConvertFrom-Json)) {
                  New-Item -ItemType Directory -Force -Path (Join-Path $d $n) | Out-Null }
                Write-Output $d
                """
            params = AgentExecStartParams(
                argv: ["powershell.exe", "-NoProfile", "-NonInteractive", "-Command", script], as: .user, timeoutMs: 30000)
        } else {
            let root =
                switch place {
                case .drop: #"r="$HOME/Desktop/VMPane Drops""#
                case .clipboard: #"r="$HOME/Library/Caches/VMPane Clipboard"; /bin/rm -rf -- "$r""#
                }
            let script = """
                \(root)
                d="$r/$(/bin/date '+%Y-%m-%d %H.%M.%S')"
                /bin/mkdir -p "$d" || exit 1
                for f in "$@"; do /bin/mkdir -p "$d/$f" || exit 1; done
                printf '%s\\n%s:%s\\n' "$d" "$(/usr/bin/id -u)" "$(/usr/bin/id -g)"
                """
            params = AgentExecStartParams(argv: ["/bin/sh", "-c", script, "sh"] + folders, as: .user, timeoutMs: 30000)
        }
        let made = try await agentExecs.run(params, on: connection)
        let lines = (String(bytes: made.stdout, encoding: .utf8) ?? "").split(whereSeparator: \.isNewline).map(String.init)
        // The path comes from the guest user's shell and steers a root chown: it must be one of these folders.
        guard made.exited?.code == 0, let path = lines.first, Self.isGuestFolder(path, place: place, windows: windows) else {
            let reason = String(bytes: made.stderr, encoding: .utf8) ?? ""
            throw RPCError(.agentUnavailable, "cannot make a folder for the files in the guest (is someone logged in?) \(reason)")
        }
        let owner = lines.dropFirst().first
        guard windows || owner.map(Self.isNumericOwner) == true else {
            throw RPCError(.internalError, "the guest named an odd owner for the files' folder")
        }
        return (path, windows ? nil : owner)
    }

    /// `…/<parents>/<time>`, absolute, no `..` (what the folder script makes at `place`; anything else is refused).
    static func isGuestFolder(_ path: String, place: GuestFolderPlace, windows: Bool) -> Bool {
        let separator: Character = windows ? "\\" : "/"
        let parts = path.split(separator: separator, omittingEmptySubsequences: false)
        let absolute = windows ? path.dropFirst().hasPrefix(":\\") : path.hasPrefix("/")
        let (grandparent, parent) = place.parents(windows: windows)
        return absolute && parts.count >= 4 && !parts.contains("..") && !parts.contains(".")
            && parts[parts.count - 3] == grandparent && parts[parts.count - 2] == parent && !parts[parts.count - 1].isEmpty
    }

    /// `uid:gid`, digits only.
    static func isNumericOwner(_ owner: String) -> Bool {
        let ids = owner.split(separator: ":", omittingEmptySubsequences: false)
        return ids.count == 2 && ids.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
    }
}

extension HelperController {
    /// `vm.files.drop` (one at a time) and `vm.files.cancel` (by the connection that started it).
    func filesRequest(_ request: RPCRequest, from connection: ControlConnection) async -> Result<JSONValue, RPCError> {
        guard request.method == ControlMethod.vmFilesDrop.rawValue else {
            guard dropOwner == ObjectIdentifier(connection) else {
                return .failure(RPCError(.invalidState, "no file drop started by this connection"))
            }
            dropTask?.cancel()
            return .success([:])
        }
        guard dropTask == nil else { return .failure(RPCError(.invalidState, "files are already being copied into the VM")) }
        let params = request.params
        let task = Task { await self.dropFiles(params, from: connection) }
        dropTask = task
        dropOwner = ObjectIdentifier(connection)
        defer {
            dropTask = nil
            dropOwner = nil
        }
        return await task.value
    }
}

/// `agent.file.push` / `agent.file.pull` params.
struct FileTransfer: Decodable {
    var hostPath: String
    var guestPath: String
    /// Replace an existing target (the guest file for a push, the host file for a pull).
    var overwrite: Bool?
}
