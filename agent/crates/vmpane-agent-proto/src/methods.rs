//! Method names, parameters and results. These types are the schema source: `proto/schema` is generated from
//! them (see [`crate::schema`]).
//!
//! Forward compatibility: unknown fields are ignored and optional fields default. A new field that changes
//! what the agent is allowed to do must come with a new cap, and the host sends it only to agents that
//! advertise that cap, so an old agent never silently ignores a restriction.

use std::collections::BTreeMap;

use schemars::JsonSchema;
use serde::{Deserialize, Serialize};

/// Method and notification names (agent protocol, not the host's control protocol).
pub mod method {
    /// guest → host, first message on every connection.
    pub const HELLO: &str = "hello";
    pub const AGENT_INFO: &str = "agent.info";
    pub const AGENT_PING: &str = "agent.ping";
    /// guest → host notification every few seconds: a write on a connection the host no longer has (after a
    /// VZ snapshot restore the guest's vsock socket survives, the host's does not) fails, so the agent reconnects.
    pub const AGENT_HEARTBEAT: &str = "agent.heartbeat";
    pub const EXEC_START: &str = "exec.start";
    pub const EXEC_SIGNAL: &str = "exec.signal";
    /// guest → host notification.
    pub const EXEC_EXITED: &str = "exec.exited";
    pub const FILE_PUSH: &str = "file.push";
    pub const FILE_PULL: &str = "file.pull";
    pub const FILE_STAT: &str = "file.stat";
    pub const FILE_MKDIR_TEMP: &str = "file.mkdirTemp";
    pub const SESSION_REVEAL: &str = "session.reveal";
    pub const CLIPBOARD_GET: &str = "clipboard.get";
    pub const CLIPBOARD_SET: &str = "clipboard.set";
    /// guest → host notification.
    pub const CLIPBOARD_CHANGED: &str = "clipboard.changed";
    pub const DISPLAY_SET: &str = "display.set";
    pub const TIME_SET: &str = "time.set";
    pub const POWER_SHUTDOWN: &str = "power.shutdown";
    pub const NET_ADDRS: &str = "net.addrs";
    pub const PORTS_LISTENING: &str = "ports.listening";
    pub const FS_FREEZE: &str = "fs.freeze";
    pub const FS_THAW: &str = "fs.thaw";
}

/// Capabilities an agent advertises in `hello`. A method whose cap is missing answers `capUnsupported`.
pub mod cap {
    pub const EXEC: &str = "exec";
    pub const FILE: &str = "file";
    /// Text, image and file clipboard (macOS guests).
    pub const CLIPBOARD: &str = "clipboard";
    /// File lists only (Linux, Windows: text and images go through spice-vdagent).
    pub const CLIPBOARD_FILES: &str = "clipboard.files";
    pub const TIME: &str = "time";
    pub const POWER: &str = "power";
    pub const NET: &str = "net";
    pub const PORTS: &str = "ports";
    pub const DISPLAY: &str = "display";
    pub const FREEZE: &str = "freeze";
    pub const REVEAL: &str = "reveal";
}

/// Who sends a method.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub enum Direction {
    HostToGuest,
    GuestToHost,
}

/// An empty object: `{}` as params or result.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct Empty {}

// MARK: hello

/// guest → host, first on every connection. The host answers with the highest version in
/// `[max(minProto, hostMin), min(proto, hostMax)]`, or `protoUnsupported`.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct HelloParams {
    /// Newest protocol version the agent speaks.
    pub proto: u32,
    /// Oldest protocol version the agent speaks.
    pub min_proto: u32,
    pub agent_version: String,
    /// `macos`, `linux` or `windows`.
    pub os: String,
    pub arch: String,
    #[serde(default)]
    pub os_version: String,
    #[serde(default)]
    pub caps: Vec<String>,
    /// A logged-in user's session helper is connected to the daemon.
    #[serde(default)]
    pub session: bool,
    /// Per-VM secret from the tools medium; required on TCP, absent on vsock and virtio-serial.
    #[serde(default)]
    pub token: Option<String>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct HelloResult {
    /// The version both sides use from now on.
    pub proto: u32,
    pub host_version: String,
}

// MARK: agent

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct AgentInfo {
    pub agent_version: String,
    pub proto: u32,
    pub os: String,
    pub arch: String,
    #[serde(default)]
    pub os_version: String,
    #[serde(default)]
    pub caps: Vec<String>,
    #[serde(default)]
    pub session: bool,
    #[serde(default)]
    pub uptime_ms: u64,
}

// MARK: exec

/// Which guest identity runs a command: the logged-in user (through the session helper) or root / LocalSystem
/// (the daemon).
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "lowercase")]
pub enum RunAs {
    #[default]
    User,
    Admin,
}

/// Starts a process. Exactly one of `argv` (run directly) and `shell` (a command line for `/bin/sh -c` or
/// `cmd.exe /c`). Output streams start at once; the end is reported by `exec.exited` after both output
/// streams ended.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct ExecStartParams {
    #[serde(default)]
    pub argv: Vec<String>,
    #[serde(default)]
    pub shell: Option<String>,
    /// Added to (and overriding) the identity's environment.
    #[serde(default)]
    pub env: BTreeMap<String, String>,
    #[serde(default)]
    pub cwd: Option<String>,
    #[serde(default, rename = "as")]
    pub run_as: RunAs,
    /// Open a stdin stream (host → guest); otherwise stdin is empty.
    #[serde(default)]
    pub stdin: bool,
    /// Kill the process tree after this long.
    #[serde(default)]
    pub timeout_ms: Option<u64>,
}

/// Stream ids are guest-allocated (even), `stdin` included: the host sends on it.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct ExecStartResult {
    pub exec_id: u32,
    pub stdout: u32,
    pub stderr: u32,
    #[serde(default)]
    pub stdin: Option<u32>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "lowercase")]
pub enum Signal {
    /// Ctrl-C (`SIGINT`, `CTRL_BREAK_EVENT`).
    Int,
    /// Ask to stop (`SIGTERM`; Windows: same as kill).
    Term,
    /// Kill the whole process tree.
    Kill,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct ExecSignalParams {
    pub exec_id: u32,
    pub signal: Signal,
}

/// guest → host notification, once per `exec.start`, after the output streams ended.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct ExecExited {
    pub exec_id: u32,
    /// Exit code; None when a signal ended the process.
    #[serde(default)]
    pub code: Option<i32>,
    #[serde(default)]
    pub signal: Option<String>,
    /// The agent killed it because `timeoutMs` passed.
    #[serde(default)]
    pub timed_out: bool,
}

// MARK: files

/// Writes a guest file from a host stream (host-allocated, odd id). The host sends the chunks right after
/// the request; the agent writes to a temporary file beside `path`, checks `size` and `sha256`, then renames.
/// The response comes after the stream ended. An early error response means the agent drops the rest.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct FilePushParams {
    /// Absolute guest path; the parent directory must exist.
    pub path: String,
    /// Unix permission bits; ignored on Windows.
    #[serde(default)]
    pub mode: Option<u32>,
    pub size: u64,
    /// Lowercase hex SHA-256 of the whole file.
    pub sha256: String,
    pub stream: u32,
    /// Replace an existing file.
    #[serde(default)]
    pub overwrite: bool,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct FilePushResult {
    pub size: u64,
    pub sha256: String,
}

/// Reads a guest file onto a guest-allocated stream. `tooLarge` when the file is bigger than `maxBytes`.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct FilePullParams {
    pub path: String,
    pub max_bytes: u64,
}

/// The data follows on `stream`; the host checks it received exactly `size` bytes.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct FilePullResult {
    pub size: u64,
    pub stream: u32,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct PathParams {
    pub path: String,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "lowercase")]
pub enum FileKind {
    #[default]
    File,
    Dir,
    Symlink,
    Other,
}

/// `file.stat` result; does not follow a final symlink.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct FileStat {
    pub kind: FileKind,
    pub size: u64,
    /// Unix permission bits; 0 on Windows.
    #[serde(default)]
    pub mode: u32,
    #[serde(default)]
    pub mtime_unix_nanos: i64,
}

/// Creates a new private directory under the user's temp directory (the drag-and-drop drop folder).
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct MkdirTempParams {
    #[serde(default)]
    pub prefix: String,
}

// MARK: clipboard

#[derive(
    Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize, JsonSchema,
)]
#[serde(rename_all = "lowercase")]
pub enum ClipboardType {
    /// UTF-8 text, on a stream.
    Text,
    /// PNG image, on a stream.
    Png,
    /// Absolute guest paths, inline.
    Files,
}

/// One clipboard representation. `text` and `png` carry `stream` and `size` (≤ 32 MiB); `files` carries
/// `files`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct ClipboardItem {
    #[serde(rename = "type")]
    pub kind: ClipboardType,
    #[serde(default)]
    pub stream: Option<u32>,
    #[serde(default)]
    pub size: Option<u64>,
    #[serde(default)]
    pub files: Vec<String>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct ClipboardGetParams {
    pub types: Vec<ClipboardType>,
}

/// `clipboard.get` result (guest-allocated streams) and `clipboard.set` params (host-allocated streams; the
/// response comes after every stream ended).
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct ClipboardContents {
    pub items: Vec<ClipboardItem>,
}

/// guest → host notification when the guest clipboard changes (rate-limited by the host).
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct ClipboardChanged {
    pub types: Vec<ClipboardType>,
    pub seq: u64,
}

// MARK: display, time, power

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct DisplaySetParams {
    pub width_px: u32,
    pub height_px: u32,
    /// Backing scale (1 or 2); the agent picks the closest mode.
    #[serde(default = "default_scale")]
    pub scale: f64,
}

fn default_scale() -> f64 {
    1.0
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct TimeSetParams {
    pub unix_nanos: i64,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct PowerShutdownParams {
    #[serde(default)]
    pub reboot: bool,
    /// Do not wait for applications to close.
    #[serde(default)]
    pub force: bool,
}

// MARK: network

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct NetInterface {
    pub name: String,
    #[serde(default)]
    pub mac: Option<String>,
    #[serde(default)]
    pub ipv4: Vec<String>,
    #[serde(default)]
    pub ipv6: Vec<String>,
}

/// `net.addrs` result. A hint only: the host trusts its own DHCP lease.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct NetAddrs {
    pub interfaces: Vec<NetInterface>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "lowercase")]
pub enum PortProto {
    Tcp,
    Udp,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct ListeningPort {
    pub proto: PortProto,
    /// Bound address (`0.0.0.0`, `::`, `127.0.0.1`, …).
    pub address: String,
    pub port: u16,
    #[serde(default)]
    pub process: Option<String>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct PortsListening {
    pub ports: Vec<ListeningPort>,
}

// MARK: freeze

/// Freezes guest file systems for a disk snapshot. They thaw by themselves after `timeoutMs` (default 10 s,
/// at most 60 s) or when the host disconnects, whichever comes first.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct FsFreezeParams {
    #[serde(default)]
    pub timeout_ms: Option<u64>,
}

/// Mount points (Linux), volumes (Windows) or nothing (macOS: only a `sync`, not a consistency point).
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct FsFreezeResult {
    pub frozen: Vec<String>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct FsThawResult {
    pub thawed: Vec<String>,
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;
    use crate::jsonrpc::decode_params;

    #[test]
    fn exec_defaults_to_the_user_and_reads_as() {
        let p: ExecStartParams = decode_params(Some(&json!({"argv": ["id"]}))).unwrap();
        assert_eq!(p.run_as, RunAs::User);
        let p: ExecStartParams =
            decode_params(Some(&json!({"shell": "id", "as": "admin"}))).unwrap();
        assert_eq!(p.run_as, RunAs::Admin);
        assert!(decode_params::<ExecStartParams>(Some(&json!({"as": "root"}))).is_err());
    }

    #[test]
    fn unknown_fields_are_ignored() {
        let p: HelloParams = decode_params(Some(&json!({
            "proto": 2, "minProto": 1, "agentVersion": "1.1", "os": "linux", "arch": "arm64", "future": [1]
        })))
        .unwrap();
        assert_eq!((p.proto, p.min_proto, p.token), (2, 1, None));
    }

    #[test]
    fn clipboard_item_uses_type() {
        let item = ClipboardItem {
            kind: ClipboardType::Text,
            stream: Some(2),
            size: Some(5),
            files: vec![],
        };
        assert_eq!(
            serde_json::to_value(&item).unwrap(),
            json!({"type": "text", "stream": 2, "size": 5, "files": []})
        );
    }
}
