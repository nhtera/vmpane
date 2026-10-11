//! The protocol description generated from the Rust types: `proto/schema/protocol.json` (methods with their
//! direction, cap and JSON Schemas, limits, error codes). Regenerate with
//! `cargo test -p vmpane-agent-proto -- --ignored regen`; a normal test fails when the committed file is stale.

use schemars::generate::SchemaSettings;
use schemars::{JsonSchema, SchemaGenerator};
use serde_json::{Map, Value, json};

use crate::error::ErrorCode;
use crate::limits::Limits;
use crate::methods::{cap, method, *};
use crate::{MIN_PROTO, PROTO};

struct Entry {
    name: &'static str,
    direction: Direction,
    /// None for notifications.
    result: Option<Value>,
    params: Value,
    cap: Option<&'static str>,
}

fn request<P: JsonSchema, R: JsonSchema>(
    g: &mut SchemaGenerator,
    name: &'static str,
    cap: Option<&'static str>,
) -> Entry {
    let params = g.subschema_for::<P>().to_value();
    let result = Some(g.subschema_for::<R>().to_value());
    Entry {
        name,
        direction: Direction::HostToGuest,
        result,
        params,
        cap,
    }
}

fn notification<P: JsonSchema>(g: &mut SchemaGenerator, name: &'static str) -> Entry {
    let params = g.subschema_for::<P>().to_value();
    Entry {
        name,
        direction: Direction::GuestToHost,
        result: None,
        params,
        cap: None,
    }
}

/// The whole protocol description, deterministic (sorted keys).
pub fn protocol_document() -> Value {
    let mut g = SchemaSettings::draft2020_12().into_generator();
    let mut hello = request::<HelloParams, HelloResult>(&mut g, method::HELLO, None);
    hello.direction = Direction::GuestToHost;
    let entries = [
        hello,
        request::<Empty, AgentInfo>(&mut g, method::AGENT_INFO, None),
        request::<Empty, Empty>(&mut g, method::AGENT_PING, None),
        notification::<Empty>(&mut g, method::AGENT_HEARTBEAT),
        request::<ExecStartParams, ExecStartResult>(&mut g, method::EXEC_START, Some(cap::EXEC)),
        request::<ExecSignalParams, Empty>(&mut g, method::EXEC_SIGNAL, Some(cap::EXEC)),
        notification::<ExecExited>(&mut g, method::EXEC_EXITED),
        request::<FilePushParams, FilePushResult>(&mut g, method::FILE_PUSH, Some(cap::FILE)),
        request::<FilePullParams, FilePullResult>(&mut g, method::FILE_PULL, Some(cap::FILE)),
        request::<PathParams, FileStat>(&mut g, method::FILE_STAT, Some(cap::FILE)),
        request::<MkdirTempParams, PathParams>(&mut g, method::FILE_MKDIR_TEMP, Some(cap::FILE)),
        request::<PathParams, Empty>(&mut g, method::SESSION_REVEAL, Some(cap::REVEAL)),
        request::<ClipboardGetParams, ClipboardContents>(&mut g, method::CLIPBOARD_GET, None),
        request::<ClipboardContents, Empty>(&mut g, method::CLIPBOARD_SET, None),
        notification::<ClipboardChanged>(&mut g, method::CLIPBOARD_CHANGED),
        request::<DisplaySetParams, Empty>(&mut g, method::DISPLAY_SET, Some(cap::DISPLAY)),
        request::<TimeSetParams, Empty>(&mut g, method::TIME_SET, Some(cap::TIME)),
        request::<PowerShutdownParams, Empty>(&mut g, method::POWER_SHUTDOWN, Some(cap::POWER)),
        request::<Empty, NetAddrs>(&mut g, method::NET_ADDRS, Some(cap::NET)),
        request::<Empty, PortsListening>(&mut g, method::PORTS_LISTENING, Some(cap::PORTS)),
        request::<FsFreezeParams, FsFreezeResult>(&mut g, method::FS_FREEZE, Some(cap::FREEZE)),
        request::<Empty, FsThawResult>(&mut g, method::FS_THAW, Some(cap::FREEZE)),
    ];
    let mut methods = Map::new();
    for e in entries {
        let mut m = Map::new();
        m.insert(
            "direction".into(),
            serde_json::to_value(e.direction).unwrap_or(Value::Null),
        );
        m.insert(
            "kind".into(),
            json!(if e.result.is_some() {
                "request"
            } else {
                "notification"
            }),
        );
        if let Some(cap) = e.cap {
            m.insert("cap".into(), json!(cap));
        }
        m.insert("params".into(), e.params);
        if let Some(result) = e.result {
            m.insert("result".into(), result);
        }
        methods.insert(e.name.into(), Value::Object(m));
    }
    let codes: Map<String, Value> = ErrorCode::ALL
        .into_iter()
        .map(|c| {
            (
                serde_json::to_value(c)
                    .ok()
                    .and_then(|v| v.as_str().map(str::to_owned))
                    .unwrap_or_default(),
                json!(c.code()),
            )
        })
        .collect();
    json!({
        "$schema": "https://json-schema.org/draft/2020-12/schema",
        "title": "VMPane agent protocol",
        "proto": PROTO,
        "minProto": MIN_PROTO,
        "limits": Limits::V1,
        "errorCodes": codes,
        "methods": methods,
        "$defs": g.take_definitions(true),
    })
}
