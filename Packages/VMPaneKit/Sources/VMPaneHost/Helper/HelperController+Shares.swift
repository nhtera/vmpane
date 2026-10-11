import Foundation
import VMPaneControl
import VMPaneCore

/// Shared folders inside the guest. VZ serves them over virtiofs (`VZMaterializer`): macOS guests mount them by
/// themselves (/Volumes/My Shared Files); a Linux guest's agent mounts the `vmpane-shares` tag at /mnt/vmpane,
/// one folder per share, each time it connects. Windows guests (QEMU) get them over WebDAV: the helper serves
/// them on 127.0.0.1 at a fresh port and under a fresh 128-bit token for each run (any process on this Mac could
/// connect to the port; only the guest learns the token), the guest reaches it at slirp's 10.0.2.2, and the
/// agent maps it as drive Z: in the logged-in user's session.
extension HelperController {
    static let linuxSharesMount = "/mnt/vmpane"

    func mountShares(_ connection: AgentConnection, peer: AgentConnection.Peer) async {
        guard backend?.kind == .vz, peer.hello.os == "linux", peer.hello.caps?.contains(AgentCap.exec) == true else { return }
        let mount = Self.linuxSharesMount
        let script = "mountpoint -q \(mount) || { mkdir -p \(mount) && mount -t virtiofs \(VZShareTag.shares) \(mount); }"
        do {
            let result = try await agentExecs.run(
                AgentExecStartParams(shell: script, as: .admin, timeoutMs: 15000), on: connection)
            if result.exited?.code != 0 {
                let message = String(bytes: result.stderr, encoding: .utf8) ?? ""
                Self.log.error("mounting the shared folders failed: \(message, privacy: .public)")
            }
        } catch {
            Self.log.error("mounting the shared folders failed: \(String(describing: error), privacy: .public)")
        }
    }
}

/// The virtiofs tags VMPane's VZ guests see (mirrors `VZPlan`, which VMPaneHost does not link).
enum VZShareTag {
    static let shares = "vmpane-shares"
}

/// A running Windows VM's WebDAV share server.
struct SharesWebDAV {
    let server: WebDAVServer
    let port: UInt16
    /// Secret: never logged.
    let token: String

    /// The URL the guest maps (slirp's 10.0.2.2 is this Mac's loopback).
    var guestURL: String { "http://10.0.2.2:\(port)/\(token)/" }
}

extension HelperController {
    static func jails(_ shares: [Extensible<ShareConfig>]) -> [String: PathJail] {
        Dictionary(
            shares.map { ($0.name, PathJail(root: URL(fileURLWithPath: $0.hostPath), readOnly: $0.readOnly)) },
            uniquingKeysWith: { first, _ in first })
    }

    /// The WebDAV server runs while a Windows VM runs.
    func webdavFollowState(_ next: VMRunState) {
        switch next {
        case .running:
            guard backend?.kind == .qemu, config.os == .windows, webdav == nil else { return }
            do {
                let (fd, port) = try WebDAVServer.loopbackListener()
                let token = (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
                let server = WebDAVServer(shares: Self.jails(config.shares), prefix: "/" + token)
                server.start(listening: fd)
                webdav = SharesWebDAV(server: server, port: port, token: token)
            } catch {
                Self.log.error("shared folders cannot be served: \(String(describing: error), privacy: .public)")
            }
        case .stopped, .error:
            webdavMapping?.cancel()
            webdavMapping = nil
            webdav?.server.stop()
            webdav = nil
        default:
            break
        }
    }

    /// Shares changed while a Windows VM runs: served at once (true when there is a server to update).
    func updateWebDAVShares(_ shares: [Extensible<ShareConfig>]) -> Bool {
        guard let webdav else { return false }
        webdav.server.update(shares: Self.jails(shares))
        return true
    }

    /// Maps the shares as Z: for the logged-in user, retrying every 10 s until someone is logged in.
    func mapSharesDrive(_ connection: AgentConnection, peer: AgentConnection.Peer) {
        guard peer.hello.os == "windows", peer.hello.caps?.contains(AgentCap.exec) == true, let webdav else { return }
        webdavMapping?.cancel()
        let execs = agentExecs
        let command = "net use Z: /delete /y >nul 2>&1 & net use Z: \(webdav.guestURL) /persistent:no"
        webdavMapping = Task {
            while !Task.isCancelled, await connection.isOpen {
                let result = try? await execs.run(
                    AgentExecStartParams(argv: ["cmd.exe", "/c", command], as: .user, timeoutMs: 60000), on: connection)
                if result?.exited?.code == 0 { return }
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }
}
