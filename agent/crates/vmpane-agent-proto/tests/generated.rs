//! Generated files under `agent/proto`: the protocol schema and the test vectors the host's Swift codec is
//! checked against. `generated_files_are_current` fails when they are stale; regenerate with
//! `cargo test -p vmpane-agent-proto -- --ignored regen`.
#![allow(clippy::expect_used)] // test helpers, not production code

use std::path::PathBuf;

use bytes::{BufMut, BytesMut};
use serde_json::{Value, json};
use vmpane_agent_proto::frame::{Frame, FrameDecoder, StreamStatus};
use vmpane_agent_proto::jsonrpc::Message;
use vmpane_agent_proto::limits::{MAX_CHUNK, MAX_JSON_DEPTH, MAX_JSON_FRAME, MAX_STRING};
use vmpane_agent_proto::{negotiate, schema};

fn proto_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../proto")
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn header(length: usize, kind: u8) -> Vec<u8> {
    let mut b = BytesMut::new();
    b.put_u32(length as u32);
    b.put_u8(kind);
    b.to_vec()
}

fn encoded(frames: &[Frame]) -> Vec<u8> {
    let mut b = BytesMut::new();
    for f in frames {
        f.encode(&mut b).expect("vector frame within limits");
    }
    b.to_vec()
}

/// Decodes `bytes` as the vectors define it: frames until more input is needed or an error.
fn frame_case(name: &str, bytes: Vec<u8>) -> Value {
    let mut buf = BytesMut::from(&bytes[..]);
    let mut decoder = FrameDecoder::new();
    let mut frames = Vec::new();
    let error = loop {
        match decoder.decode(&mut buf) {
            Ok(Some(Frame::Message(json))) => {
                frames.push(json!({"type": "message", "json": String::from_utf8_lossy(&json)}))
            }
            Ok(Some(Frame::Chunk { stream, data })) => {
                frames.push(json!({"type": "chunk", "stream": stream, "hex": hex(&data)}))
            }
            Ok(Some(Frame::End { stream, status })) => {
                let status = match status {
                    StreamStatus::Ok => "ok",
                    StreamStatus::Error => "error",
                    StreamStatus::Cancelled => "cancelled",
                };
                frames.push(json!({"type": "end", "stream": stream, "status": status}))
            }
            Ok(None) => break Value::Null,
            Err(err) => break json!(err.kind()),
        }
    };
    json!({"name": name, "hex": hex(&bytes), "frames": frames, "error": error, "remaining": error.is_null().then_some(buf.len())})
}

fn frame_vectors() -> Value {
    let ping = br#"{"jsonrpc":"2.0","id":1,"method":"agent.ping"}"#;
    let message = Frame::Message(ping.as_slice().into());
    let chunk = Frame::Chunk {
        stream: 3,
        data: b"hello"[..].into(),
    };
    let mut cases = vec![
        frame_case("message", encoded(std::slice::from_ref(&message))),
        frame_case("chunk", encoded(std::slice::from_ref(&chunk))),
        frame_case(
            "end ok",
            encoded(&[Frame::End {
                stream: 3,
                status: StreamStatus::Ok,
            }]),
        ),
        frame_case(
            "end error",
            encoded(&[Frame::End {
                stream: 4,
                status: StreamStatus::Error,
            }]),
        ),
        frame_case(
            "end cancelled",
            encoded(&[Frame::End {
                stream: 5,
                status: StreamStatus::Cancelled,
            }]),
        ),
        frame_case(
            "three frames back to back",
            encoded(&[message.clone(), chunk.clone(), message.clone()]),
        ),
        frame_case("empty message payload", header(1, 0)),
    ];
    let whole = encoded(&[chunk]);
    cases.push(frame_case("partial header", whole[..3].to_vec()));
    cases.push(frame_case(
        "partial payload",
        whole[..whole.len() - 1].to_vec(),
    ));
    let mut then_partial = encoded(&[message]);
    then_partial.extend_from_slice(&whole[..7]);
    cases.push(frame_case("whole frame then a partial one", then_partial));
    cases.extend([
        frame_case("zero length", vec![0, 0, 0, 0]),
        frame_case("unknown type", vec![0, 0, 0, 1, 9]),
        frame_case("largest message header", header(1 + MAX_JSON_FRAME, 0)),
        frame_case("message one byte too large", header(2 + MAX_JSON_FRAME, 0)),
        frame_case("largest chunk header", header(5 + MAX_CHUNK, 1)),
        frame_case("chunk one byte too large", header(6 + MAX_CHUNK, 1)),
        frame_case("length 0xffffffff", vec![0xff, 0xff, 0xff, 0xff, 0]),
        frame_case("chunk without data", vec![0, 0, 0, 5, 1, 0, 0, 0, 1]),
        frame_case(
            "chunk shorter than its stream id",
            vec![0, 0, 0, 3, 1, 0, 0],
        ),
        frame_case("chunk on stream 0", vec![0, 0, 0, 6, 1, 0, 0, 0, 0, 0x41]),
        frame_case("end too short", vec![0, 0, 0, 5, 2, 0, 0, 0, 1]),
        frame_case("end too long", vec![0, 0, 0, 7, 2, 0, 0, 0, 1, 0, 0]),
        frame_case("end unknown status", vec![0, 0, 0, 6, 2, 0, 0, 0, 1, 3]),
        frame_case("end on stream 0", vec![0, 0, 0, 6, 2, 0, 0, 0, 0, 0]),
    ]);
    json!({"description": "Frame decoding: decode until more input is needed (error null, `remaining` bytes left) or an error.", "cases": cases})
}

/// A message case; `@PAD@` in `json` stands for `pad` repetitions of "a" (keeps long strings out of the file).
fn message_case(name: &str, json_text: &str, pad: usize) -> Value {
    let text = json_text.replace("@PAD@", &"a".repeat(pad));
    message_result(
        json!({"name": name, "json": json_text, "pad": pad}),
        text.as_bytes(),
    )
}

fn message_result(mut case: Value, bytes: &[u8]) -> Value {
    let expect = match Message::parse(bytes) {
        Ok(Message::Request(r)) => {
            json!({"kind": "request", "id": Message::Request(r.clone()).to_value()["id"], "method": r.method, "hasParams": r.params.is_some()})
        }
        Ok(Message::Notification(n)) => {
            json!({"kind": "notification", "method": n.method, "hasParams": n.params.is_some()})
        }
        Ok(Message::Response(r)) => {
            let id = Message::Response(r.clone()).to_value()["id"].clone();
            match r.outcome {
                Ok(_) => json!({"kind": "response", "id": id, "ok": true}),
                Err(e) => json!({"kind": "response", "id": id, "ok": false, "errorCode": e.code}),
            }
        }
        Err(err) => json!({"kind": "error", "error": err.kind()}),
    };
    case["expect"] = expect;
    case
}

fn message_vectors() -> Value {
    let nest = |n: usize| format!("{}{}", "[".repeat(n), "]".repeat(n));
    let depth_ok = format!(
        r#"{{"jsonrpc":"2.0","method":"m","params":{}}}"#,
        nest(MAX_JSON_DEPTH - 1)
    );
    let depth_over = format!(
        r#"{{"jsonrpc":"2.0","method":"m","params":{}}}"#,
        nest(MAX_JSON_DEPTH)
    );
    let quoted = format!(
        r#"{{"jsonrpc":"2.0","method":"m","params":{{"s":"\"{}"}}}}"#,
        "[{".repeat(40)
    );
    let mut cases = vec![
        message_case(
            "request, integer id",
            r#"{"jsonrpc":"2.0","id":7,"method":"agent.ping"}"#,
            0,
        ),
        message_case(
            "request, string id",
            r#"{"jsonrpc":"2.0","id":"a1","method":"file.stat","params":{"path":"/"}}"#,
            0,
        ),
        message_case(
            "request, negative id",
            r#"{"jsonrpc":"2.0","id":-9007199254740993,"method":"m"}"#,
            0,
        ),
        message_case(
            "notification",
            r#"{"jsonrpc":"2.0","method":"exec.exited","params":{"execId":1,"code":0}}"#,
            0,
        ),
        message_case(
            "response result",
            r#"{"jsonrpc":"2.0","id":1,"result":{"proto":1,"hostVersion":"1.0"}}"#,
            0,
        ),
        message_case(
            "response error",
            r#"{"jsonrpc":"2.0","id":"x","error":{"code":-32017,"message":"no common version","data":{"proto":1}}}"#,
            0,
        ),
        message_case(
            "response error, null id",
            r#"{"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"parse"}}"#,
            0,
        ),
        message_case(
            "unknown members ignored",
            r#"{"jsonrpc":"2.0","id":1,"method":"m","future":{"x":[1]}}"#,
            0,
        ),
        message_case(
            "params array",
            r#"{"jsonrpc":"2.0","method":"m","params":[1,2]}"#,
            0,
        ),
        message_case(
            "escapes and unicode",
            r#"{"jsonrpc":"2.0","method":"m","params":{"s":"é\n\\\"é😀"}}"#,
            0,
        ),
        message_case("depth at the limit", &depth_ok, 0),
        message_case("depth one over the limit", &depth_over, 0),
        message_case("brackets inside a string", &quoted, 0),
        message_case(
            "string at the limit",
            r#"{"jsonrpc":"2.0","method":"m","params":{"s":"@PAD@"}}"#,
            MAX_STRING,
        ),
        message_case(
            "string one over the limit",
            r#"{"jsonrpc":"2.0","method":"m","params":{"s":"@PAD@"}}"#,
            MAX_STRING + 1,
        ),
        message_case(
            "key one over the limit",
            r#"{"jsonrpc":"2.0","method":"m","params":{"@PAD@":1}}"#,
            MAX_STRING + 1,
        ),
        message_case(
            "method one over the limit",
            r#"{"jsonrpc":"2.0","method":"@PAD@"}"#,
            MAX_STRING + 1,
        ),
        message_case("batch (array)", r#"[{"jsonrpc":"2.0","method":"m"}]"#, 0),
        message_case("not an object", r#""hello""#, 0),
        message_case("jsonrpc missing", r#"{"id":1,"method":"m"}"#, 0),
        message_case("jsonrpc 1.0", r#"{"jsonrpc":"1.0","id":1,"method":"m"}"#, 0),
        message_case(
            "method not a string",
            r#"{"jsonrpc":"2.0","id":1,"method":5}"#,
            0,
        ),
        message_case(
            "fractional id",
            r#"{"jsonrpc":"2.0","id":1.5,"method":"m"}"#,
            0,
        ),
        message_case(
            "null request id",
            r#"{"jsonrpc":"2.0","id":null,"method":"m"}"#,
            0,
        ),
        message_case(
            "boolean id",
            r#"{"jsonrpc":"2.0","id":true,"method":"m"}"#,
            0,
        ),
        message_case(
            "id above Int64",
            r#"{"jsonrpc":"2.0","id":9223372036854775808,"method":"m"}"#,
            0,
        ),
        message_case(
            "params a number",
            r#"{"jsonrpc":"2.0","method":"m","params":1}"#,
            0,
        ),
        message_case("response without id", r#"{"jsonrpc":"2.0","result":1}"#, 0),
        message_case("response with neither", r#"{"jsonrpc":"2.0","id":1}"#, 0),
        message_case(
            "response with both",
            r#"{"jsonrpc":"2.0","id":1,"result":1,"error":{"code":1,"message":"m"}}"#,
            0,
        ),
        message_case(
            "result with null id",
            r#"{"jsonrpc":"2.0","id":null,"result":1}"#,
            0,
        ),
        message_case(
            "error code not an integer",
            r#"{"jsonrpc":"2.0","id":1,"error":{"code":1.5,"message":"m"}}"#,
            0,
        ),
        message_case(
            "error code beyond Int32",
            r#"{"jsonrpc":"2.0","id":1,"error":{"code":4294967296,"message":"m"}}"#,
            0,
        ),
        message_case(
            "error without message",
            r#"{"jsonrpc":"2.0","id":1,"error":{"code":1}}"#,
            0,
        ),
        message_case("truncated", r#"{"jsonrpc":"2.0","method":"#, 0),
        message_case("trailing garbage", r#"{"jsonrpc":"2.0","method":"m"} x"#, 0),
        message_case("empty", "", 0),
    ];
    let mut invalid_utf8 = br#"{"jsonrpc":"2.0","method":"m","params":{"s":""#.to_vec();
    invalid_utf8.extend_from_slice(b"\xff\"}}");
    cases.push(message_result(
        json!({"name": "invalid UTF-8", "hex": hex(&invalid_utf8)}),
        &invalid_utf8,
    ));
    json!({
        "description": "Message parsing. Input is `json` (with `@PAD@` replaced by `pad` × \"a\") or `hex`. Checks run in order: depth on raw bytes, syntax, string lengths, JSON-RPC shape.",
        "cases": cases,
    })
}

fn negotiation_vectors() -> Value {
    let pairs = [
        ((1, 1), (1, 1)),
        ((1, 3), (2, 5)),
        ((2, 5), (1, 3)),
        ((1, 2), (3, 4)),
        ((3, 4), (1, 2)),
        ((1, 5), (2, 2)),
        ((2, 1), (1, 2)),
    ];
    let cases: Vec<Value> = pairs
        .into_iter()
        .map(|(host, agent)| json!({"host": [host.0, host.1], "agent": [agent.0, agent.1], "expect": negotiate(host, agent)}))
        .collect();
    json!({"description": "Version negotiation: the highest version in both [min, max] ranges, null when none.", "cases": cases})
}

fn files() -> Vec<(PathBuf, String)> {
    let render = |v: Value| {
        format!(
            "{}\n",
            serde_json::to_string_pretty(&v).expect("JSON values serialize")
        )
    };
    let dir = proto_dir();
    vec![
        (
            dir.join("schema/protocol.json"),
            render(schema::protocol_document()),
        ),
        (dir.join("vectors/frames.json"), render(frame_vectors())),
        (dir.join("vectors/messages.json"), render(message_vectors())),
        (
            dir.join("vectors/negotiation.json"),
            render(negotiation_vectors()),
        ),
    ]
}

#[test]
#[ignore = "writes agent/proto; run with --ignored regen"]
fn regen() {
    for (path, text) in files() {
        std::fs::create_dir_all(path.parent().expect("has a parent")).expect("create proto dir");
        std::fs::write(&path, text).expect("write generated file");
    }
}

#[test]
fn generated_files_are_current() {
    for (path, text) in files() {
        // A Windows checkout may turn line endings into CRLF: the text is what must match.
        let committed = std::fs::read_to_string(&path)
            .unwrap_or_default()
            .replace("\r\n", "\n");
        assert!(
            committed == text,
            "{} is stale: cargo test -p vmpane-agent-proto -- --ignored regen",
            path.display()
        );
    }
}
