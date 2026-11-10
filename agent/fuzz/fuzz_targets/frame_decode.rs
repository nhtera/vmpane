//! Arbitrary bytes, fed in arbitrary pieces, into the frame decoder: never a panic, never more buffered than
//! one maximal frame plus the latest piece, and every frame it returns re-encodes to the bytes it came from.
#![no_main]

use bytes::BytesMut;
use libfuzzer_sys::fuzz_target;
use vmpane_agent_proto::frame::{Frame, FrameDecoder, HEADER_LEN};
use vmpane_agent_proto::jsonrpc::Message;
use vmpane_agent_proto::limits::MAX_JSON_FRAME;

fuzz_target!(|data: &[u8]| {
    let Some((&piece, input)) = data.split_first() else {
        return;
    };
    let piece = usize::from(piece % 32) + 1;
    let mut decoder = FrameDecoder::new();
    let mut buf = BytesMut::new();
    // The decoder only takes bytes off the front, so the buffer is always `input[consumed..fed]` and a frame it
    // returns must re-encode to the input from `consumed`. The check reads the input in place: a copy of the buffer
    // per piece fed (up to a frame's worth, thousands of times per input) left the allocator so fragmented under
    // ASan that the fuzzer passed libFuzzer's 2 GiB RSS limit with 27 MB of live heap (2026-11-07).
    let mut consumed = 0;
    let mut fed = 0;
    for chunk in input.chunks(piece) {
        buf.extend_from_slice(chunk);
        fed += chunk.len();
        loop {
            match decoder.decode(&mut buf) {
                Ok(Some(frame)) => {
                    let encoded = frame.to_bytes().expect("a decoded frame re-encodes");
                    assert!(
                        encoded.len() <= fed - consumed,
                        "a frame longer than what was fed"
                    );
                    assert_eq!(&encoded[..], &input[consumed..consumed + encoded.len()]);
                    consumed += encoded.len();
                    assert_eq!(
                        buf.len(),
                        fed - consumed,
                        "the buffer holds what was fed and not yet decoded"
                    );
                    if let Frame::Message(json) = frame {
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
