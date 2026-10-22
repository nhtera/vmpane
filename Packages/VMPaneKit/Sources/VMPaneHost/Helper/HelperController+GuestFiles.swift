import Foundation
import VMPaneControl
import VMPaneCore

/// Guest files and folders copied onto the Mac (files copied in the guest, files dragged out of its window): each one
/// into a `HostFileSink` (sanitized names, no links followed, quarantine, a budget), folders walked in the guest.
extension HelperController {
    /// One thing inside a guest folder: its path below that folder ("/"-separated) and whether it is a folder.
    struct GuestEntry: Equatable {
        let path: String
        let isFolder: Bool
    }

    /// The guest files come from: its agent's connection, the helper's commands on it, and its kind of paths.
    struct Guest {
        let connection: AgentConnection
        let execs: AgentExecs
        let windows: Bool
    }

    /// Copies guest `paths` (files or folders) into `sink` below `prefix` ("" or "a/b/"); returns where each top-level
    /// one landed. Links and special files are skipped. A name that is taken gets " 2"; `named` names a single path's
    /// copy (what Finder asked a file promise for) instead of the guest.
    static func pullTree(_ paths: [String], into sink: HostFileSink, under prefix: String, from guest: Guest, named: String? = nil)
        async throws -> [URL]
    {
        let (connection, windows) = (guest.connection, guest.windows)
        var landed: [URL] = []
        for path in paths {
            let name = paths.count == 1 ? named ?? Self.guestName(path) : Self.guestName(path)
            let stat = try await connection.call(
                AgentMethod.fileStat, RPCParams.encode(AgentPathParams(path: path)).get(), timeout: .seconds(30))
            switch try RPCParams.decode(AgentFileStat.self, from: stat.result).get().kind {
            case .file:
                landed.append(try await pullFile(path, as: prefix + name, into: sink, on: connection))
            case .dir:
                let folder = try sink.createFolder(prefix + name, unique: true)
                let top = prefix + folder.lastPathComponent + "/"
                for entry in try await guestFolder(path, windows: windows, execs: guest.execs, on: connection) {
                    if entry.isFolder {
                        _ = try sink.createFolder(top + entry.path)
                    } else {
                        let child = path + (windows ? "\\" + entry.path.replacingOccurrences(of: "/", with: "\\") : "/" + entry.path)
                        _ = try await pullFile(child, as: top + entry.path, into: sink, on: connection)
                    }
                }
                landed.append(folder)
            case .symlink, .other:
                continue
            }
        }
        return landed
    }

    /// The last component of a guest path (either separator).
    static func guestName(_ path: String) -> String {
        path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? path
    }

    private static func pullFile(_ path: String, as relative: String, into sink: HostFileSink, on connection: AgentConnection) async throws
        -> URL
    {
        let (handle, url) = try sink.create(relative)
        do {
            try await pull(path, into: handle, sink: sink, on: connection)
            try handle.close()
            return url
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    /// Everything in guest folder `path`, folders before their contents, links not followed, listed as the guest's user
    /// (at most `HostFileSink.defaultMaxFiles` + 1: a bigger folder is refused by the sink's budget anyway). Names travel
    /// base64-encoded UTF-8, so no shell or code page changes them.
    static func guestFolder(_ path: String, windows: Bool, execs: AgentExecs, on connection: AgentConnection) async throws -> [GuestEntry] {
        let limit = HostFileSink.defaultMaxFiles + 1
        let params: AgentExecStartParams
        if windows {
            let script = """
                $p = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('\(Data(path.utf8).base64EncodedString())'))
                $script:n = 0
                function W($d, $r) {
                  foreach ($c in Get-ChildItem -LiteralPath $d -Force -ErrorAction SilentlyContinue) {
                    if ($c.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
                    if (++$script:n -gt \(limit)) { exit 0 }
                    $rel = if ($r) { $r + '/' + $c.Name } else { $c.Name }
                    $t = if ($c.PSIsContainer) { 'd' } else { 'f' }
                    Write-Output ($t + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($rel)))
                    if ($c.PSIsContainer) { W $c.FullName $rel } } }
                W $p ''
                """
            params = AgentExecStartParams(
                argv: ["powershell.exe", "-NoProfile", "-NonInteractive", "-Command", script], as: .user, timeoutMs: 60000)
        } else {
            // find -P (the default) never follows a link; the names come out base64-encoded, one per line.
            let script = """
                cd -- "$1" || exit 1
                /usr/bin/find . -mindepth 1 \\( -type d -o -type f \\) -print | /usr/bin/head -n \(limit) | while IFS= read -r p; do
                  if [ -d "$p" ]; then t=d; else t=f; fi
                  printf '%s%s\\n' "$t" "$(printf '%s' "${p#./}" | /usr/bin/base64)"
                done
                """
            params = AgentExecStartParams(argv: ["/bin/sh", "-c", script, "sh", path], as: .user, timeoutMs: 60000)
        }
        let listed = try await execs.run(params, on: connection)
        guard listed.exited?.code == 0 else {
            throw RPCError(.internalError, "cannot list \(path) in the guest: \(String(bytes: listed.stderr, encoding: .utf8) ?? "")")
        }
        return Self.guestEntries(String(bytes: listed.stdout, encoding: .utf8) ?? "")
    }

    /// The listing's lines: `d` or `f`, then the base64 UTF-8 path; anything else is dropped.
    static func guestEntries(_ listing: String) -> [GuestEntry] {
        listing.split(whereSeparator: \.isNewline).compactMap { line in
            guard let kind = line.first, kind == "d" || kind == "f",
                let data = Data(base64Encoded: String(line.dropFirst()).trimmingCharacters(in: .whitespaces)),
                let path = String(data: data, encoding: .utf8), !path.isEmpty
            else { return nil }
            return GuestEntry(path: path, isFolder: kind == "d")
        }
    }
}
