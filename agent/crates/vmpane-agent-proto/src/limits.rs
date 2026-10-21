//! Limits both sides enforce. Defined once here, exported into the generated schema and checked by the host's
//! conformance tests through the shared vectors.

use schemars::JsonSchema;
use serde::Serialize;

/// Largest JSON-RPC message payload (frame type 0), in bytes.
pub const MAX_JSON_FRAME: usize = 1 << 20;
/// Largest stream chunk payload (frame type 1, after the stream id), in bytes.
pub const MAX_CHUNK: usize = 256 << 10;
/// Streams open at once on one connection, both directions together.
pub const MAX_OPEN_STREAMS: usize = 16;
/// Deepest nesting of objects and arrays in a JSON message; the top-level object is depth 1.
pub const MAX_JSON_DEPTH: usize = 32;
/// Longest JSON string or object key, in UTF-8 bytes after unescaping. Larger data travels on a stream.
pub const MAX_STRING: usize = 64 << 10;
/// Largest clipboard text or image, carried on a stream.
pub const MAX_CLIPBOARD_BYTES: u64 = 32 << 20;
/// `clipboard.changed` notifications the host accepts per second before it drops the connection.
pub const MAX_CLIPBOARD_CHANGED_PER_SECOND: u32 = 10;
/// Seconds between `agent.heartbeat` notifications.
pub const HEARTBEAT_SECONDS: u64 = 5;
/// `fs.freeze` thaws by itself after this long when the request gives no timeout.
pub const FREEZE_DEFAULT_TIMEOUT_MS: u64 = 10_000;
/// Longest `fs.freeze` timeout the agent accepts.
pub const FREEZE_MAX_TIMEOUT_MS: u64 = 60_000;
/// `screen.elements`: at most this many elements, names this many characters, this deep below the window.
pub const SCREEN_MAX_ELEMENTS: u32 = 800;
pub const SCREEN_MAX_NAME: usize = 120;
pub const SCREEN_MAX_DEPTH: u32 = 12;

/// The limits as a value, for the generated schema.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct Limits {
    pub max_json_frame: usize,
    pub max_chunk: usize,
    pub max_open_streams: usize,
    pub max_json_depth: usize,
    pub max_string: usize,
    pub max_clipboard_bytes: u64,
    pub max_clipboard_changed_per_second: u32,
    pub freeze_default_timeout_ms: u64,
    pub freeze_max_timeout_ms: u64,
}

impl Limits {
    pub const V1: Limits = Limits {
        max_json_frame: MAX_JSON_FRAME,
        max_chunk: MAX_CHUNK,
        max_open_streams: MAX_OPEN_STREAMS,
        max_json_depth: MAX_JSON_DEPTH,
        max_string: MAX_STRING,
        max_clipboard_bytes: MAX_CLIPBOARD_BYTES,
        max_clipboard_changed_per_second: MAX_CLIPBOARD_CHANGED_PER_SECOND,
        freeze_default_timeout_ms: FREEZE_DEFAULT_TIMEOUT_MS,
        freeze_max_timeout_ms: FREEZE_MAX_TIMEOUT_MS,
    };
}
