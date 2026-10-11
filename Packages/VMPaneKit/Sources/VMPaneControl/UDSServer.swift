import Darwin
import Foundation
import VMPaneCore

/// JSON-RPC server on a Unix socket (the helper's `run/<sid>.sock`).
///
/// - The socket is created 0600 inside a 0700 directory.
/// - Every accepted peer must have our uid (`LOCAL_PEERCRED`); others, and any beyond `maxConnections`, are
///   closed at once.
/// - Requests run concurrently; responses carry the request id. Notifications get no response.
public final class UDSServer: @unchecked Sendable {
    /// Handles one request. The result is sent back unless the request was a notification.
    public typealias Handler = @Sendable (RPCRequest, ControlConnection) async -> Result<JSONValue, RPCError>

    public let socketURL: URL
    /// A client that does not read for this long is disconnected.
    static let sendTimeoutSeconds = 10
    /// Connections beyond this are closed at once, so a flood cannot use up the descriptors the VM needs.
    static let maxConnections = 128
    private let handler: Handler
    private let queue = DispatchQueue(label: "app.vmpane.control.server")
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var connections: Set<ControlConnection> = []

    public init(socketURL: URL, handler: @escaping Handler) {
        self.socketURL = socketURL
        self.handler = handler
    }

    /// Binds and listens. Replaces a stale socket file: only the bundle-lock holder may call this.
    public func start() throws {
        let directory = socketURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        chmod(directory.path, 0o700)
        unlink(socketURL.path)
        let fd = try UnixSocket.make()
        do {
            try UnixSocket.bind(fd, to: UnixSocketAddress(socketURL))
            // The directory is 0700, so the moment between bind and chmod exposes nothing.
            guard chmod(socketURL.path, 0o600) == 0, listen(fd, 16) == 0 else { throw POSIXError.current() }
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        } catch {
            close(fd)
            throw error
        }
        listenFD = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptPending() }
        source.setCancelHandler { close(fd) }
        acceptSource = source
        source.resume()
    }

    /// Stops listening, closes every connection and removes the socket file.
    public func stop() {
        queue.sync {
            acceptSource?.cancel()
            acceptSource = nil
            for connection in connections { connection.close() }
            connections.removeAll()
        }
        unlink(socketURL.path)
    }

    /// Current connections (e.g. to send notifications).
    public var activeConnections: [ControlConnection] {
        queue.sync { Array(connections) }
    }

    /// Sends a notification to every connection subscribed to `topic`.
    public func broadcast(topic: String, method: String, params: JSONValue?) {
        for connection in activeConnections { connection.notify(topic: topic, method: method, params: params) }
    }

    private func acceptPending() {
        while true {
            let fd = accept(listenFD, nil, nil)
            if fd < 0 {
                if errno == EMFILE || errno == ENFILE, let source = acceptSource {
                    // Out of descriptors: the level-triggered source would fire again at once. Pause briefly.
                    source.suspend()
                    queue.asyncAfter(deadline: .now() + 0.2) { source.resume() }
                }
                return  // EAGAIN: drained
            }
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
            // Accepted sockets inherit O_NONBLOCK from the listener. Connections write blocking on their own
            // queue (a full send buffer must wait, not fail), with a send timeout that drops stuck clients.
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
            var enabled: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
            var timeout = timeval(tv_sec: Self.sendTimeoutSeconds, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            guard connections.count < Self.maxConnections, let peer = try? PeerCredentials.of(socket: fd), peer.uid == geteuid() else {
                close(fd)
                continue
            }
            let connection = ControlConnection(
                fd: fd, peer: peer,
                onLine: { [weak self] connection, line in self?.handle(line, from: connection) },
                onClose: { [weak self] connection in
                    guard let server = self else { return }
                    server.queue.async { server.connections.remove(connection) }
                })
            connections.insert(connection)
            connection.start()
        }
    }

    private func handle(_ line: Data, from connection: ControlConnection) {
        switch RPCCodec.decode(line) {
        case .failure(let failure):
            connection.send(.response(RPCResponse(id: failure.id, error: failure.error)))
        case .success(.response):
            break  // clients do not answer the server
        case .success(.request(let request)):
            let handler = handler
            connection.beginRequest()
            Task {
                let result = await handler(request, connection)
                if let id = request.id {
                    switch result {
                    case .success(let value): connection.send(.response(RPCResponse(id: id, result: value)))
                    case .failure(let error): connection.send(.response(RPCResponse(id: id, error: error)))
                    }
                }
                connection.finishRequest()  // queued after the response, so the response goes out first
            }
        }
    }
}
