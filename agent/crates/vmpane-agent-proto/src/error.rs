//! Errors: frame and message decoding (each one means "drop the connection"), and the JSON-RPC error codes
//! the agent protocol uses.

use schemars::JsonSchema;
use serde::Serialize;

/// A frame broke the format or a limit. The stream is no longer at a frame boundary: drop the connection.
#[derive(Debug, Clone, Copy, PartialEq, Eq, thiserror::Error)]
pub enum FrameError {
    #[error("frame length out of range for its type")]
    BadLength,
    #[error("frame larger than the limit")]
    TooLarge,
    #[error("unknown frame type")]
    BadType,
    #[error("stream id 0")]
    BadStream,
    #[error("unknown stream end status")]
    BadStatus,
}

impl FrameError {
    /// Name used by the shared test vectors.
    pub fn kind(self) -> &'static str {
        match self {
            FrameError::BadLength => "badLength",
            FrameError::TooLarge => "tooLarge",
            FrameError::BadType => "badType",
            FrameError::BadStream => "badStream",
            FrameError::BadStatus => "badStatus",
        }
    }
}

/// Errors of the tokio-util codec: a frame error or the I/O error under it.
#[cfg(feature = "tokio-codec")]
#[derive(Debug, thiserror::Error)]
pub enum CodecError {
    #[error(transparent)]
    Frame(#[from] FrameError),
    #[error(transparent)]
    Io(#[from] std::io::Error),
}

/// A message payload is not a valid JSON-RPC 2.0 message within the limits. Drop the connection.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum ParseError {
    #[error("not UTF-8 JSON")]
    Parse,
    #[error("JSON nested deeper than the limit")]
    Depth,
    #[error("JSON string longer than the limit")]
    StringTooLong,
    #[error("not a JSON-RPC 2.0 message: {0}")]
    Invalid(&'static str),
}

impl ParseError {
    /// Name used by the shared test vectors.
    pub fn kind(&self) -> &'static str {
        match self {
            ParseError::Parse => "parse",
            ParseError::Depth => "depth",
            ParseError::StringTooLong => "string",
            ParseError::Invalid(_) => "invalid",
        }
    }
}

/// JSON-RPC error codes: the standard ones, the host's `protoUnsupported` (same value as the control protocol),
/// and the agent's own (-32040…).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
#[repr(i32)]
pub enum ErrorCode {
    ParseError = -32700,
    InvalidRequest = -32600,
    MethodNotFound = -32601,
    InvalidParams = -32602,
    InternalError = -32603,
    /// `hello` found no protocol version both sides speak.
    ProtoUnsupported = -32017,
    /// A request other than `hello` came first.
    HelloRequired = -32040,
    /// The agent does not have the capability the request needs (a cap it did not advertise).
    CapUnsupported = -32041,
    /// The path, exec id or stream does not exist.
    NotFound = -32042,
    PermissionDenied = -32043,
    /// A guest I/O call failed; the message says which.
    Io = -32044,
    Timeout = -32045,
    /// A size limit (`maxBytes`, clipboard size, open streams).
    TooLarge = -32046,
    /// Another operation holds what this one needs (a freeze in progress, a file being written).
    Busy = -32047,
    /// `as: "user"` or a session method with no logged-in user's session helper.
    NoSession = -32048,
    /// Received data does not match its announced size or SHA-256.
    Integrity = -32049,
    /// `hello` on TCP with a missing or wrong token.
    Unauthorized = -32050,
}

impl ErrorCode {
    pub const ALL: [ErrorCode; 17] = [
        ErrorCode::ParseError,
        ErrorCode::InvalidRequest,
        ErrorCode::MethodNotFound,
        ErrorCode::InvalidParams,
        ErrorCode::InternalError,
        ErrorCode::ProtoUnsupported,
        ErrorCode::HelloRequired,
        ErrorCode::CapUnsupported,
        ErrorCode::NotFound,
        ErrorCode::PermissionDenied,
        ErrorCode::Io,
        ErrorCode::Timeout,
        ErrorCode::TooLarge,
        ErrorCode::Busy,
        ErrorCode::NoSession,
        ErrorCode::Integrity,
        ErrorCode::Unauthorized,
    ];

    pub fn code(self) -> i32 {
        self as i32
    }

    pub fn from_code(code: i32) -> Option<ErrorCode> {
        ErrorCode::ALL.into_iter().find(|c| c.code() == code)
    }
}
