import Darwin
import Foundation
import Testing
import VMPaneCore

@testable import VMPaneHost

/// Accepts connections on `socket` and plays each script (one per connection) on its own thread.
private func serve(_ socket: URL, _ scripts: [[Data]]) throws -> Thread {
    let listener = try UnixSocket.make()
    try UnixSocket.bind(listener, to: .absolute(socket.path))
    listen(listener, 4)
    let thread = Thread {
        for script in scripts {
            let fd = accept(listener, nil, nil)
            guard fd >= 0 else { break }
            for chunk in script {
                try? UnixSocket.writeAll(fd, chunk)
                usleep(50_000)
            }
            close(fd)
        }
        close(listener)
    }
    thread.start()
    return thread
}

@Test func guestLinesArriveCappedAndAcrossReconnects() async throws {
    let dir = URL(fileURLWithPath: "/private/tmp/vp-gl-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let socket = dir.appendingPathComponent("agent.sock")
    _ = try serve(
        socket,
        [
            [Data("VMPANE-INSTALL firstLogon\r\n".utf8), Data("partial".utf8), Data(" line\n".utf8)],
            // A line over the cap drops this connection; what follows it on the same connection is lost.
            [Data(repeating: 0x41, count: GuestLineReader.maxLineBytes + 10) + Data("\nlost\n".utf8)],
            // QEMU restarted: the reader connects again.
            [Data([0xFF, 0xFE, 0x0A]), Data("VMPANE-INSTALL toolsInstalled\n".utf8)],
        ])
    let reader = GuestLineReader(socket: socket)
    var received: [String] = []
    for await line in reader.lines {
        received.append(line)
        if received.count == 3 { break }
    }
    reader.stop()
    #expect(received == ["VMPANE-INSTALL firstLogon", "partial line", "VMPANE-INSTALL toolsInstalled"])
}
