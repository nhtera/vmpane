import Darwin
import Foundation
import VMPaneControl
import VMPaneCore

/// Keeps the helper connected to a Unix socket that QEMU listens on for the agent's virtio-serial port
/// (`run/<sid>/agent.sock`). The connection exists before the guest agent runs, so `hello` may take as long
/// as the guest takes to boot; when it closes (the agent restarted, QEMU restarted), the link reconnects. A guest
/// that carried on from saved memory keeps its old session until the connection tells it to say `hello` again.
public actor UDSAgentLink {
    private let socket: URL
    private let hub: AgentHub
    private let hostVersion: String
    private var task: Task<Void, Never>?
    private var connection: AgentConnection?

    public init(socket: URL, hub: AgentHub, hostVersion: String) {
        self.socket = socket
        self.hub = hub
        self.hostVersion = hostVersion
    }

    public func start() {
        guard task == nil else { return }
        task = Task { [weak self] in await self?.run() }
    }

    /// Stops reconnecting and closes the connection, whether or not the agent said hello.
    public func stop() async {
        task?.cancel()
        task = nil
        await connection?.close(.closed("the VM stopped"))
        connection = nil
    }

    private func run() async {
        while !Task.isCancelled {
            await hub.waitOutBackoff()
            guard let fd = Self.connect(socket) else {
                try? await Task.sleep(for: .seconds(1))
                continue
            }
            let connection = AgentConnection(fd: fd, hostVersion: hostVersion, portOutlivesConnections: true)
            self.connection = connection
            guard !Task.isCancelled else { break }
            await hub.serve(connection, helloTimeout: nil)
            self.connection = nil
            try? await Task.sleep(for: .seconds(1))
        }
        await connection?.close(.closed("the VM stopped"))
    }

    private static func connect(_ url: URL) -> Int32? {
        guard let fd = try? UnixSocket.make() else { return nil }
        guard (try? UnixSocket.connect(fd, to: UnixSocketAddress(url))) != nil else {
            close(fd)
            return nil
        }
        return fd
    }
}
