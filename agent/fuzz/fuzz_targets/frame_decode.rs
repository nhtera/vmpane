//! Arbitrary bytes, fed in arbitrary pieces, into the frame decoder: never a panic, never more buffered than
//! one maximal frame plus the latest piece, and every frame it returns re-encodes to the bytes it came from.
#![no_main]

use bytes::BytesMut;
use libfuzzer_sys::fuzz_target;
use vmpane_agent_proto::frame::{FrameDecoder, HEADER_LEN};
use vmpane_agent_proto::jsonrpc::Message;
use vmpane_agent_proto::limits::MAX_JSON_FRAME;

fuzz_target!(|data: &[u8]| {
    let Some((&piece, input)) = data.split_first() else { return };
    let piece = usize::from(piece % 32) + 1;
    let mut decoder = FrameDecoder::new();
    let mut buf = BytesMut::new();
    for chunk in input.chunks(piece) {
        buf.extend_from_slice(chunk);
        loop {
            let before = buf.clone();
            match decoder.decode(&mut buf) {
                Ok(Some(frame)) => {
                    let encoded = frame.to_bytes().expect("a decoded frame re-encodes");
                    assert_eq!(&encoded[..], &before[..encoded.len()]);
                    if let vmpane_agent_proto::frame::Frame::Message(json) = frame {
                        let _ = Message::parse(&json);
                    }
                }
                Ok(None) => break,
                Err(_) => return,
            }
        }
        assert!(buf.len() <= HEADER_LEN + MAX_JSON_FRAME + piece);
    }
});
