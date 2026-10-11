//! Frames: `u32 BE length | u8 type | payload`, where `length` counts the type byte and the payload.
//!
//! - type 0, JSON-RPC message: payload is one UTF-8 JSON object, at most [`MAX_JSON_FRAME`] bytes.
//! - type 1, stream chunk: `u32 BE stream id | bytes`, 1 to [`MAX_CHUNK`] bytes.
//! - type 2, stream end: `u32 BE stream id | u8 status` ([`StreamStatus`]).
//!
//! Stream ids are never 0. The side that names a stream in a request allocates its id: the host uses odd ids,
//! the guest even ones, so the two never collide. Data flows from the frame's sender to its receiver.
//!
//! The decoder rejects a frame from its 5-byte header alone when the length is out of range, so a peer can
//! never make the other side buffer more than one maximal frame.

use bytes::{Buf, BufMut, Bytes, BytesMut};

use crate::error::FrameError;
use crate::limits::{MAX_CHUNK, MAX_JSON_FRAME};

pub const TYPE_MESSAGE: u8 = 0;
pub const TYPE_CHUNK: u8 = 1;
pub const TYPE_END: u8 = 2;

/// Length field + type byte.
pub const HEADER_LEN: usize = 5;

/// How a stream ended.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum StreamStatus {
    /// All data was sent.
    Ok = 0,
    /// The sender failed part way; the data is incomplete.
    Error = 1,
    /// The sender or receiver gave up (cancel, timeout, disconnect of the consumer).
    Cancelled = 2,
}

impl StreamStatus {
    pub fn from_u8(value: u8) -> Option<StreamStatus> {
        match value {
            0 => Some(StreamStatus::Ok),
            1 => Some(StreamStatus::Error),
            2 => Some(StreamStatus::Cancelled),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Frame {
    /// One JSON-RPC message, not yet parsed (see [`crate::jsonrpc::Message::parse`]).
    Message(Bytes),
    Chunk {
        stream: u32,
        data: Bytes,
    },
    End {
        stream: u32,
        status: StreamStatus,
    },
}

/// True for ids the host allocates (odd), false for the guest's (even).
pub fn is_host_stream(stream: u32) -> bool {
    stream % 2 == 1
}

impl Frame {
    /// Appends the encoded frame to `dst`. Fails, writing nothing, when the frame breaks a limit.
    pub fn encode(&self, dst: &mut BytesMut) -> Result<(), FrameError> {
        match self {
            Frame::Message(json) => {
                if json.len() > MAX_JSON_FRAME {
                    return Err(FrameError::TooLarge);
                }
                put_header(dst, 1 + json.len(), TYPE_MESSAGE);
                dst.put_slice(json);
            }
            Frame::Chunk { stream, data } => {
                check_stream(*stream)?;
                if data.is_empty() {
                    return Err(FrameError::BadLength);
                }
                if data.len() > MAX_CHUNK {
                    return Err(FrameError::TooLarge);
                }
                put_header(dst, 5 + data.len(), TYPE_CHUNK);
                dst.put_u32(*stream);
                dst.put_slice(data);
            }
            Frame::End { stream, status } => {
                check_stream(*stream)?;
                put_header(dst, 6, TYPE_END);
                dst.put_u32(*stream);
                dst.put_u8(*status as u8);
            }
        }
        Ok(())
    }

    pub fn to_bytes(&self) -> Result<Bytes, FrameError> {
        let mut buf = BytesMut::new();
        self.encode(&mut buf)?;
        Ok(buf.freeze())
    }
}

fn put_header(dst: &mut BytesMut, length: usize, kind: u8) {
    dst.reserve(4 + length);
    // Lengths are bounded by the limits above, far below u32::MAX.
    dst.put_u32(length as u32);
    dst.put_u8(kind);
}

fn check_stream(stream: u32) -> Result<(), FrameError> {
    if stream == 0 {
        Err(FrameError::BadStream)
    } else {
        Ok(())
    }
}

/// Checks a frame header (`length` = type byte + payload) before any payload is buffered.
fn check_header(length: usize, kind: u8) -> Result<(), FrameError> {
    let payload = length.checked_sub(1).ok_or(FrameError::BadLength)?;
    match kind {
        TYPE_MESSAGE if payload > MAX_JSON_FRAME => Err(FrameError::TooLarge),
        TYPE_MESSAGE => Ok(()),
        TYPE_CHUNK if payload <= 4 => Err(FrameError::BadLength),
        TYPE_CHUNK if payload - 4 > MAX_CHUNK => Err(FrameError::TooLarge),
        TYPE_CHUNK => Ok(()),
        TYPE_END if payload != 5 => Err(FrameError::BadLength),
        TYPE_END => Ok(()),
        _ => Err(FrameError::BadType),
    }
}

/// Decodes frames from a byte buffer as it fills. After an error the connection must be dropped: the buffer
/// is no longer at a frame boundary.
#[derive(Debug, Default)]
pub struct FrameDecoder;

impl FrameDecoder {
    pub fn new() -> FrameDecoder {
        FrameDecoder
    }

    /// Takes one whole frame off the front of `src`; `Ok(None)` when more bytes are needed.
    pub fn decode(&mut self, src: &mut BytesMut) -> Result<Option<Frame>, FrameError> {
        if src.len() < HEADER_LEN {
            // A zero length is already wrong with four bytes; reject it without waiting for a type byte.
            if src.len() >= 4 && src[..4] == [0, 0, 0, 0] {
                return Err(FrameError::BadLength);
            }
            return Ok(None);
        }
        let length = u32::from_be_bytes([src[0], src[1], src[2], src[3]]) as usize;
        let kind = src[4];
        check_header(length, kind)?;
        if src.len() < 4 + length {
            src.reserve(4 + length - src.len());
            return Ok(None);
        }
        src.advance(HEADER_LEN);
        let mut payload = src.split_to(length - 1);
        let frame = match kind {
            TYPE_MESSAGE => Frame::Message(payload.freeze()),
            TYPE_CHUNK => {
                let stream = payload.get_u32();
                check_stream(stream)?;
                Frame::Chunk {
                    stream,
                    data: payload.freeze(),
                }
            }
            _ => {
                let stream = payload.get_u32();
                check_stream(stream)?;
                let status =
                    StreamStatus::from_u8(payload.get_u8()).ok_or(FrameError::BadStatus)?;
                Frame::End { stream, status }
            }
        };
        Ok(Some(frame))
    }
}

#[cfg(feature = "tokio-codec")]
mod codec {
    use bytes::BytesMut;
    use tokio_util::codec::{Decoder, Encoder};

    use super::{Frame, FrameDecoder};
    use crate::error::CodecError;

    impl Decoder for FrameDecoder {
        type Item = Frame;
        type Error = CodecError;

        fn decode(&mut self, src: &mut BytesMut) -> Result<Option<Frame>, CodecError> {
            Ok(FrameDecoder::decode(self, src)?)
        }
    }

    impl Encoder<Frame> for FrameDecoder {
        type Error = CodecError;

        fn encode(&mut self, frame: Frame, dst: &mut BytesMut) -> Result<(), CodecError> {
            Ok(frame.encode(dst)?)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn decode_all(bytes: &[u8]) -> (Vec<Frame>, Result<(), FrameError>, usize) {
        let mut buf = BytesMut::from(bytes);
        let mut decoder = FrameDecoder::new();
        let mut frames = Vec::new();
        loop {
            match decoder.decode(&mut buf) {
                Ok(Some(frame)) => frames.push(frame),
                Ok(None) => return (frames, Ok(()), buf.len()),
                Err(err) => return (frames, Err(err), buf.len()),
            }
        }
    }

    #[test]
    fn round_trips_every_type() {
        let frames = [
            Frame::Message(Bytes::from_static(
                br#"{"jsonrpc":"2.0","method":"agent.ping","id":1}"#,
            )),
            Frame::Chunk {
                stream: 3,
                data: Bytes::from_static(b"hello"),
            },
            Frame::End {
                stream: 3,
                status: StreamStatus::Cancelled,
            },
        ];
        let mut buf = BytesMut::new();
        for frame in &frames {
            frame.encode(&mut buf).unwrap();
        }
        let (decoded, result, rest) = decode_all(&buf);
        assert_eq!(decoded, frames);
        assert_eq!(result, Ok(()));
        assert_eq!(rest, 0);
    }

    #[test]
    fn waits_for_a_whole_frame_byte_by_byte() {
        let bytes = Frame::Chunk {
            stream: 2,
            data: Bytes::from_static(b"abc"),
        }
        .to_bytes()
        .unwrap();
        let mut buf = BytesMut::new();
        let mut decoder = FrameDecoder::new();
        for (i, byte) in bytes.iter().enumerate() {
            buf.put_u8(*byte);
            let frame = decoder.decode(&mut buf).unwrap();
            assert_eq!(frame.is_some(), i == bytes.len() - 1);
        }
    }

    #[test]
    fn rejects_oversized_frames_from_the_header() {
        let mut header = BytesMut::new();
        header.put_u32((MAX_JSON_FRAME + 2) as u32);
        header.put_u8(TYPE_MESSAGE);
        assert_eq!(decode_all(&header).1, Err(FrameError::TooLarge));

        let mut chunk = BytesMut::new();
        chunk.put_u32((MAX_CHUNK + 6) as u32);
        chunk.put_u8(TYPE_CHUNK);
        assert_eq!(decode_all(&chunk).1, Err(FrameError::TooLarge));
    }

    #[test]
    fn largest_frames_pass() {
        let json = Bytes::from(vec![b' '; MAX_JSON_FRAME]);
        let chunk = Bytes::from(vec![7; MAX_CHUNK]);
        let mut buf = BytesMut::new();
        Frame::Message(json).encode(&mut buf).unwrap();
        Frame::Chunk {
            stream: 1,
            data: chunk,
        }
        .encode(&mut buf)
        .unwrap();
        let (frames, result, _) = decode_all(&buf);
        assert_eq!((frames.len(), result), (2, Ok(())));
    }

    #[test]
    fn rejects_malformed_frames() {
        let cases: [(&[u8], FrameError); 7] = [
            (&[0, 0, 0, 0], FrameError::BadLength),
            (&[0, 0, 0, 1, 9], FrameError::BadType),
            (&[0, 0, 0, 5, 1, 0, 0, 0, 1], FrameError::BadLength),
            (&[0, 0, 0, 6, 1, 0, 0, 0, 0, 7], FrameError::BadStream),
            (&[0, 0, 0, 5, 2, 0, 0, 0, 1], FrameError::BadLength),
            (&[0, 0, 0, 6, 2, 0, 0, 0, 1, 3], FrameError::BadStatus),
            (&[0, 0, 0, 6, 2, 0, 0, 0, 0, 0], FrameError::BadStream),
        ];
        for (bytes, expected) in cases {
            assert_eq!(decode_all(bytes).1, Err(expected), "{bytes:?}");
        }
    }

    #[test]
    fn encoder_refuses_what_the_decoder_would_reject() {
        let empty = Frame::Chunk {
            stream: 1,
            data: Bytes::new(),
        };
        let zero = Frame::End {
            stream: 0,
            status: StreamStatus::Ok,
        };
        let big = Frame::Message(Bytes::from(vec![b' '; MAX_JSON_FRAME + 1]));
        assert_eq!(empty.to_bytes(), Err(FrameError::BadLength));
        assert_eq!(zero.to_bytes(), Err(FrameError::BadStream));
        assert_eq!(big.to_bytes(), Err(FrameError::TooLarge));
    }

    #[test]
    fn stream_parity() {
        assert!(is_host_stream(1));
        assert!(!is_host_stream(2));
    }
}
