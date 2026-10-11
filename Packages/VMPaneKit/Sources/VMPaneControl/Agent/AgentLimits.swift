/// Agent protocol limits. Mirror of `vmpane-agent-proto::limits`; the conformance tests check these against
/// the generated `agent/proto/schema/protocol.json`.
public enum AgentLimits {
    /// Largest JSON-RPC message payload (frame type 0), in bytes.
    public static let maxJSONFrame = 1 << 20
    /// Largest stream chunk payload (frame type 1, after the stream id), in bytes.
    public static let maxChunk = 256 << 10
    /// Streams open at once on one connection, both directions together.
    public static let maxOpenStreams = 16
    /// Deepest nesting of objects and arrays; the top-level object is depth 1.
    public static let maxJSONDepth = 32
    /// Longest JSON string or object key, in UTF-8 bytes after unescaping.
    public static let maxString = 64 << 10
    /// Largest clipboard text or image, carried on a stream.
    public static let maxClipboardBytes: UInt64 = 32 << 20
    /// `clipboard.changed` notifications accepted per second before the connection is dropped.
    public static let maxClipboardChangedPerSecond = 10
    public static let freezeDefaultTimeoutMs: UInt64 = 10_000
    public static let freezeMaxTimeoutMs: UInt64 = 60_000

    /// Protocol versions this host speaks: `minProto`…`proto`. The floor stays 1 for all of v1.x.
    public static let proto: UInt32 = 1
    public static let minProto: UInt32 = 1

    /// vsock port the host listens on (VZ guests).
    public static let vsockPort: UInt32 = 6271
    /// virtio-serial port name (QEMU guests).
    public static let serialPortName = "app.vmpane.agent.0"

    /// The version two peers use: the highest one in both ranges, nil when they do not overlap.
    public static func negotiate(host: ClosedRange<UInt32>, agentMin: UInt32, agentMax: UInt32) -> UInt32? {
        guard agentMin <= agentMax else { return nil }
        let low = max(host.lowerBound, agentMin)
        let high = min(host.upperBound, agentMax)
        return low <= high ? high : nil
    }
}
