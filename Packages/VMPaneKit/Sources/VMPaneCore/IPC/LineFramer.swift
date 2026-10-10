import Foundation

/// Splits a byte stream into newline-delimited JSON lines with a per-line size cap (control protocol, QMP).
public struct LineFramer: Sendable {
    public enum Event: Equatable, Sendable {
        case line(Data)
        /// A line exceeded the limit: send an error and close the connection.
        case overflow
    }

    private var buffer = Data()
    private let maxLineBytes: Int

    public init(maxLineBytes: Int) {
        self.maxLineBytes = maxLineBytes
    }

    /// Appends received bytes and returns complete lines (empty lines skipped, `\r\n` accepted).
    public mutating func append(_ data: Data) -> [Event] {
        buffer.append(data)
        var events: [Event] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            var line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            if line.last == 0x0D { line = line.dropLast() }
            if line.count > maxLineBytes { return events + [.overflow] }
            if !line.isEmpty { events.append(.line(Data(line))) }
        }
        if buffer.count > maxLineBytes { events.append(.overflow) }
        return events
    }
}
