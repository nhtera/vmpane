//! Arbitrary bytes as a JSON-RPC message: never a panic, and whatever parses re-encodes within the limits and
//! parses back to the same message.
#![no_main]

use libfuzzer_sys::fuzz_target;
use vmpane_agent_proto::jsonrpc::Message;

fuzz_target!(|data: &[u8]| {
    if let Ok(message) = Message::parse(data) {
        let bytes = message.to_bytes().expect("a parsed message re-encodes");
        assert_eq!(Message::parse(&bytes).expect("and parses again"), message);
    }
});
