import Foundation
import VMPaneControl

/// Data the guest sends on one stream, buffered for one consumer. Above `highWater` buffered bytes the
/// connection stops reading the socket until the consumer catches up, so a fast guest cannot fill host memory.
public final class AgentInbound: @unchecked Sendable {
    public enum Failure: Error, Equatable, Sendable {
        /// The guest ended the stream with `error` or `cancelled`.
        case ended(AgentFrame.StreamStatus)
        /// The connection closed before the stream ended.
        case disconnected
    }

    static let highWater = 4 << 20

    public let id: UInt32
    private let lock = NSLock()
    private var chunks: [Data] = []
    private var buffered = 0
    private var outcome: Result<Void, Failure>?
    private var reader: CheckedContinuation<Data?, Error>?
    private var roomWaiter: CheckedContinuation<Void, Never>?
    private var discarding = false

    init(id: UInt32) { self.id = id }

    /// Nobody will read this stream: drop its data as it arrives (and let a paused connection read again).
    public func discard() {
        let waiter = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            discarding = true
            chunks.removeAll()
            buffered = 0
            defer { roomWaiter = nil }
            return roomWaiter
        }
        waiter?.resume()
    }

    /// Adds data; true when the buffer is above the high-water mark (wait with `waitForRoom`).
    func push(_ data: Data) -> Bool {
        let (waiting, full) = lock.withLock { () -> (CheckedContinuation<Data?, Error>?, Bool) in
            if discarding { return (nil, false) }
            if let reader {
                self.reader = nil
                return (reader, false)
            }
            chunks.append(data)
            buffered += data.count
            return (nil, buffered > Self.highWater)
        }
        waiting?.resume(returning: data)
        return full
    }

    /// Returns once the consumer took enough to be below the high-water mark (or the stream is over).
    func waitForRoom() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let ready = lock.withLock { () -> Bool in
                if buffered <= Self.highWater || outcome != nil { return true }
                roomWaiter = continuation
                return false
            }
            if ready { continuation.resume() }
        }
    }

    func finish(_ result: Result<Void, Failure>) {
        let (waiting, room) = lock.withLock { () -> (CheckedContinuation<Data?, Error>?, CheckedContinuation<Void, Never>?) in
            guard outcome == nil else { return (nil, nil) }
            outcome = result
            defer {
                reader = nil
                roomWaiter = nil
            }
            return (chunks.isEmpty ? reader : nil, roomWaiter)
        }
        room?.resume()
        switch result {
        case .success: waiting?.resume(returning: nil)
        case .failure(let failure): waiting?.resume(throwing: failure)
        }
    }

    /// The next piece of data; nil when the stream ended normally. Throws when it ended otherwise.
    public func next() async throws -> Data? {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data?, Error>) in
            enum Step {
                case data(Data, CheckedContinuation<Void, Never>?)
                case end(Result<Void, Failure>)
                case wait
            }
            let step = lock.withLock { () -> Step in
                if !chunks.isEmpty {
                    let data = chunks.removeFirst()
                    buffered -= data.count
                    var room: CheckedContinuation<Void, Never>?
                    if buffered <= Self.highWater {
                        room = roomWaiter
                        roomWaiter = nil
                    }
                    return .data(data, room)
                }
                if let outcome { return .end(outcome) }
                reader = continuation
                return .wait
            }
            switch step {
            case .data(let data, let room):
                room?.resume()
                continuation.resume(returning: data)
            case .end(.success): continuation.resume(returning: nil)
            case .end(.failure(let failure)): continuation.resume(throwing: failure)
            case .wait: break
            }
        }
    }

    /// Everything up to the end of the stream; throws `tooLarge`-style errors past `limit` bytes.
    public func collect(limit: Int) async throws -> Data {
        var all = Data()
        do {
            while let data = try await next() {
                all.append(data)
                guard all.count <= limit else { throw Failure.ended(.cancelled) }
            }
        } catch {
            discard()  // the rest must not hold the connection up
            throw error
        }
        return all
    }
}
