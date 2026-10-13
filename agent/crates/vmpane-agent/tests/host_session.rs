//! The agent binary against a stand-in host over a Unix socket: hello, exec, files, freeze, protocol limits.
#![cfg(unix)]
#![allow(clippy::unwrap_used, clippy::expect_used)] // test code

use std::collections::HashMap;
use std::path::PathBuf;
use std::process::Stdio;
use std::sync::atomic::{AtomicU32, Ordering};
use std::time::Duration;

use bytes::{Bytes, BytesMut};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::UnixListener;
use tokio::net::unix::{OwnedReadHalf, OwnedWriteHalf};
use vmpane_agent_proto::frame::{Frame, FrameDecoder, StreamStatus};
use vmpane_agent_proto::jsonrpc::{Id, Message, Request, Response};

static COUNTER: AtomicU32 = AtomicU32::new(0);

fn scratch() -> PathBuf {
    let dir = std::env::temp_dir().join(format!(
        "vpa-{}-{}",
        std::process::id(),
        COUNTER.fetch_add(1, Ordering::Relaxed)
    ));
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

struct Host {
    reader: OwnedReadHalf,
    writer: OwnedWriteHalf,
    decoder: FrameDecoder,
    buf: BytesMut,
    next_id: i64,
    streams: HashMap<u32, Vec<u8>>,
    ended: HashMap<u32, StreamStatus>,
    notifications: Vec<(String, Value)>,
    child: tokio::process::Child,
    dir: PathBuf,
    hello: Value,
}

impl Host {
    async fn start() -> Host {
        Host::start_in(scratch(), &[]).await
    }

    /// A daemon that also accepts session helpers of this test's uid on `<dir>/session.sock`.
    async fn start_with_sessions() -> Host {
        let uid = nix::unistd::getuid().as_raw().to_string();
        let dir = scratch();
        let socket = dir.join("session.sock").display().to_string();
        Host::start_in(dir, &["--session-socket", &socket, "--session-uid", &uid]).await
    }

    async fn start_in(dir: PathBuf, extra: &[&str]) -> Host {
        let socket = dir.join("s");
        let listener = UnixListener::bind(&socket).unwrap();
        let child = tokio::process::Command::new(env!("CARGO_BIN_EXE_vmpane-agent"))
            .args(["--connect", &format!("unix:{}", socket.display()), "--once"])
            .args(extra)
            .stderr(Stdio::null())
            .kill_on_drop(true)
            .spawn()
            .unwrap();
        let (stream, _) = tokio::time::timeout(Duration::from_secs(10), listener.accept())
            .await
            .unwrap()
            .unwrap();
        let (reader, writer) = stream.into_split();
        let mut host = Host {
            reader,
            writer,
            decoder: FrameDecoder::new(),
            buf: BytesMut::new(),
            next_id: 100,
            streams: HashMap::new(),
            ended: HashMap::new(),
            notifications: Vec::new(),
            child,
            dir,
            hello: Value::Null,
        };
        let Message::Request(hello) = host.next_message().await else {
            panic!("expected hello")
        };
        assert_eq!(hello.method, "hello");
        host.hello = hello.params.clone().unwrap();
        host.send(Response::ok(hello.id, &json!({"proto": 1, "hostVersion": "test"})).into())
            .await;
        host
    }

    async fn send_frame(&mut self, frame: Frame) {
        self.writer
            .write_all(&frame.to_bytes().unwrap())
            .await
            .unwrap();
    }

    async fn send(&mut self, message: Message) {
        let bytes = message.to_bytes().unwrap();
        self.send_frame(Frame::Message(bytes.into())).await;
    }

    /// Next frame; stream data and notifications are recorded, messages returned.
    async fn next_frame(&mut self) -> Option<Frame> {
        loop {
            if let Some(frame) = self.decoder.decode(&mut self.buf).unwrap() {
                return Some(frame);
            }
            let read =
                tokio::time::timeout(Duration::from_secs(20), self.reader.read_buf(&mut self.buf))
                    .await
                    .unwrap()
                    .unwrap();
            if read == 0 {
                return None;
            }
        }
    }

    async fn next_message(&mut self) -> Message {
        loop {
            match self.next_frame().await.expect("connection closed") {
                Frame::Message(bytes) => {
                    let message = Message::parse(&bytes).unwrap();
                    if let Message::Notification(n) = &message {
                        self.notifications
                            .push((n.method.clone(), n.params.clone().unwrap_or(Value::Null)));
                        continue;
                    }
                    return message;
                }
                Frame::Chunk { stream, data } => self
                    .streams
                    .entry(stream)
                    .or_default()
                    .extend_from_slice(&data),
                Frame::End { stream, status } => {
                    self.ended.insert(stream, status);
                }
            }
        }
    }

    async fn request(&mut self, method: &str, params: Value) -> i64 {
        self.next_id += 1;
        let id = self.next_id;
        self.send(Request::new(Id::Int(id), method, &params).into())
            .await;
        id
    }

    async fn response(&mut self, id: i64) -> Result<Value, (i32, String)> {
        loop {
            if let Message::Response(r) = self.next_message().await
                && r.id == Some(Id::Int(id))
            {
                return r.outcome.map_err(|e| (e.code, e.message));
            }
        }
    }

    async fn call(&mut self, method: &str, params: Value) -> Result<Value, (i32, String)> {
        let id = self.request(method, params).await;
        self.response(id).await
    }

    /// Reads until `exec.exited` for `exec_id` arrives.
    async fn exited(&mut self, exec_id: u64) -> Value {
        loop {
            if let Some((_, params)) = self
                .notifications
                .iter()
                .find(|(m, p)| m == "exec.exited" && p["execId"] == exec_id)
            {
                return params.clone();
            }
            let _ = self.next_frame_into_state().await;
        }
    }

    async fn next_frame_into_state(&mut self) -> Option<()> {
        match self.next_frame().await? {
            Frame::Message(bytes) => {
                if let Ok(Message::Notification(n)) = Message::parse(&bytes) {
                    self.notifications
                        .push((n.method, n.params.unwrap_or(Value::Null)));
                }
            }
            Frame::Chunk { stream, data } => self
                .streams
                .entry(stream)
                .or_default()
                .extend_from_slice(&data),
            Frame::End { stream, status } => {
                self.ended.insert(stream, status);
            }
        }
        Some(())
    }

    async fn until_ended(&mut self, stream: u32) -> StreamStatus {
        while !self.ended.contains_key(&stream) {
            self.next_frame_into_state()
                .await
                .expect("connection closed");
        }
        self.ended[&stream]
    }

    async fn exec(&mut self, params: Value) -> (Vec<u8>, Vec<u8>, Value) {
        let started = self.call("exec.start", params).await.unwrap();
        let (out, err) = (
            started["stdout"].as_u64().unwrap() as u32,
            started["stderr"].as_u64().unwrap() as u32,
        );
        assert_eq!(out % 2, 0, "guest streams are even");
        let exited = self.exited(started["execId"].as_u64().unwrap()).await;
        assert_eq!(self.ended.get(&out), Some(&StreamStatus::Ok));
        assert_eq!(self.ended.get(&err), Some(&StreamStatus::Ok));
        (
            self.streams.remove(&out).unwrap_or_default(),
            self.streams.remove(&err).unwrap_or_default(),
            exited,
        )
    }
}

impl Drop for Host {
    fn drop(&mut self) {
        let _ = self.child.start_kill();
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

#[tokio::test]
async fn hello_info_and_ping() {
    let mut host = Host::start().await;
    assert_eq!(host.hello["proto"], 1);
    assert_eq!(host.hello["minProto"], 1);
    assert_eq!(host.hello["os"], std::env::consts::OS);
    assert!(
        host.hello["caps"]
            .as_array()
            .unwrap()
            .contains(&json!("exec"))
    );
    assert_eq!(host.hello["token"], Value::Null);
    assert_eq!(host.call("agent.ping", json!({})).await, Ok(json!({})));
    let info = host.call("agent.info", json!({})).await.unwrap();
    assert_eq!(info["proto"], 1);
    assert_eq!(host.call("no.such", json!({})).await.unwrap_err().0, -32601);
    assert_eq!(
        host.call("display.set", json!({"widthPx": 1, "heightPx": 1}))
            .await
            .unwrap_err()
            .0,
        -32041
    );
}

#[tokio::test]
async fn exec_streams_output_and_exit_codes() {
    let mut host = Host::start().await;
    let (out, err, exited) = host
        .exec(json!({"shell": "echo hello; echo oops >&2; exit 3", "as": "admin"}))
        .await;
    assert_eq!(
        (out.as_slice(), err.as_slice()),
        (&b"hello\n"[..], &b"oops\n"[..])
    );
    assert_eq!(exited["code"], 3);
    let (out, _, exited) = host
        .exec(json!({"argv": ["/bin/echo", "a b"], "as": "admin", "env": {"X": "1"}}))
        .await;
    assert_eq!(
        (out.as_slice(), &exited["code"]),
        (&b"a b\n"[..], &json!(0))
    );
    // The user identity needs the session helper.
    assert_eq!(
        host.call("exec.start", json!({"argv": ["id"]}))
            .await
            .unwrap_err()
            .0,
        -32048
    );
    assert_eq!(
        host.call("exec.start", json!({"as": "admin"}))
            .await
            .unwrap_err()
            .0,
        -32602
    );
    let missing = host
        .call(
            "exec.start",
            json!({"argv": ["/no/such/program"], "as": "admin"}),
        )
        .await;
    assert_eq!(missing.unwrap_err().0, -32042);
}

#[tokio::test]
async fn exec_stdin_timeout_and_signal() {
    let mut host = Host::start().await;
    let started = host
        .call(
            "exec.start",
            json!({"argv": ["/bin/cat"], "as": "admin", "stdin": true}),
        )
        .await
        .unwrap();
    let stdin = started["stdin"].as_u64().unwrap() as u32;
    host.send_frame(Frame::Chunk {
        stream: stdin,
        data: Bytes::from_static(b"piped"),
    })
    .await;
    host.send_frame(Frame::End {
        stream: stdin,
        status: StreamStatus::Ok,
    })
    .await;
    let exited = host.exited(started["execId"].as_u64().unwrap()).await;
    assert_eq!(exited["code"], 0);
    assert_eq!(
        host.streams
            .remove(&(started["stdout"].as_u64().unwrap() as u32))
            .unwrap(),
        b"piped"
    );

    let started = std::time::Instant::now();
    let (_, _, exited) = host
        .exec(json!({"shell": "sleep 30 & sleep 30", "as": "admin", "timeoutMs": 300}))
        .await;
    assert_eq!(exited["timedOut"], true);
    assert_eq!(exited["signal"], "SIGKILL");
    assert!(
        started.elapsed() < Duration::from_secs(10),
        "the whole group died with the timeout"
    );

    let running = host
        .call(
            "exec.start",
            json!({"argv": ["/bin/sleep", "30"], "as": "admin"}),
        )
        .await
        .unwrap();
    let exec_id = running["execId"].as_u64().unwrap();
    host.call("exec.signal", json!({"execId": exec_id, "signal": "term"}))
        .await
        .unwrap();
    assert_eq!(host.exited(exec_id).await["signal"], "SIGTERM");
    assert_eq!(
        host.call("exec.signal", json!({"execId": 999, "signal": "kill"}))
            .await
            .unwrap_err()
            .0,
        -32042
    );
}

#[tokio::test]
async fn files_push_pull_and_stat() {
    let mut host = Host::start().await;
    let data: Vec<u8> = (0..700_000u32).map(|i| (i * 7 % 251) as u8).collect();
    let sha = hex(&Sha256::digest(&data));
    let target = host.dir.join("pushed.bin");
    let id = host
        .request(
            "file.push",
            json!({"path": target, "size": data.len(), "sha256": sha, "stream": 1, "mode": 0o640}),
        )
        .await;
    for piece in data.chunks(256 << 10) {
        host.send_frame(Frame::Chunk {
            stream: 1,
            data: Bytes::copy_from_slice(piece),
        })
        .await;
    }
    host.send_frame(Frame::End {
        stream: 1,
        status: StreamStatus::Ok,
    })
    .await;
    assert_eq!(
        host.response(id).await.unwrap(),
        json!({"size": data.len(), "sha256": sha})
    );
    assert_eq!(std::fs::read(&target).unwrap(), data);

    let stat = host
        .call("file.stat", json!({"path": target}))
        .await
        .unwrap();
    assert_eq!(
        (&stat["kind"], &stat["size"], &stat["mode"]),
        (&json!("file"), &json!(data.len()), &json!(0o640))
    );

    // Exists without overwrite → refused before any data; the host's chunks are dropped.
    let id = host
        .request(
            "file.push",
            json!({"path": target, "size": 1, "sha256": sha, "stream": 3}),
        )
        .await;
    host.send_frame(Frame::Chunk {
        stream: 3,
        data: Bytes::from_static(b"x"),
    })
    .await;
    host.send_frame(Frame::End {
        stream: 3,
        status: StreamStatus::Ok,
    })
    .await;
    assert_eq!(host.response(id).await.unwrap_err().0, -32047);

    // Wrong checksum → integrity error, nothing left behind.
    let other = host.dir.join("bad.bin");
    let id = host
        .request(
            "file.push",
            json!({"path": other, "size": 2, "sha256": sha, "stream": 5}),
        )
        .await;
    host.send_frame(Frame::Chunk {
        stream: 5,
        data: Bytes::from_static(b"no"),
    })
    .await;
    host.send_frame(Frame::End {
        stream: 5,
        status: StreamStatus::Ok,
    })
    .await;
    assert_eq!(host.response(id).await.unwrap_err().0, -32049);
    assert!(!other.exists());
    assert_eq!(
        std::fs::read_dir(&host.dir).unwrap().count(),
        2,
        "only the socket and pushed.bin"
    );

    let pulled = host
        .call("file.pull", json!({"path": target, "maxBytes": 1 << 30}))
        .await
        .unwrap();
    let stream = pulled["stream"].as_u64().unwrap() as u32;
    assert_eq!(host.until_ended(stream).await, StreamStatus::Ok);
    assert_eq!(host.streams.remove(&stream).unwrap(), data);
    assert_eq!(
        host.call("file.pull", json!({"path": target, "maxBytes": 10}))
            .await
            .unwrap_err()
            .0,
        -32046
    );
    assert_eq!(
        host.call("file.stat", json!({"path": "relative"}))
            .await
            .unwrap_err()
            .0,
        -32602
    );
    assert_eq!(
        host.call("file.stat", json!({"path": "/no/such"}))
            .await
            .unwrap_err()
            .0,
        -32042
    );
}

#[tokio::test]
async fn freeze_thaw_and_bad_frames() {
    let mut host = Host::start().await;
    match host.call("fs.freeze", json!({"timeoutMs": 2000})).await {
        Ok(frozen) => {
            assert!(frozen["frozen"].is_array());
            assert_eq!(
                host.call("fs.freeze", json!({})).await.unwrap_err().0,
                -32047
            );
            assert!(host.call("fs.thaw", json!({})).await.unwrap()["thawed"].is_array());
        }
        // Linux without CAP_SYS_ADMIN (CI runs tests unprivileged).
        Err((code, _)) => assert_eq!(code, -32043),
    }
    assert_eq!(
        host.call("fs.freeze", json!({"timeoutMs": 61_000}))
            .await
            .unwrap_err()
            .0,
        -32602
    );

    // A frame over the limit: the agent drops the connection and (with --once) exits.
    let mut header = BytesMut::new();
    header.extend_from_slice(&((2 + (1 << 20)) as u32).to_be_bytes());
    header.extend_from_slice(&[0]);
    host.writer.write_all(&header).await.unwrap();
    while host.next_frame_into_state().await.is_some() {}
    let status = tokio::time::timeout(Duration::from_secs(10), host.child.wait())
        .await
        .unwrap()
        .unwrap();
    assert!(status.success());
}

fn session_helper(dir: &std::path::Path, pretend_version: Option<&str>) -> tokio::process::Child {
    let mut cmd = tokio::process::Command::new(env!("CARGO_BIN_EXE_vmpane-agent"));
    let socket = dir.join("session.sock").display().to_string();
    cmd.args(["session", "--socket", &socket, "--once"])
        .stderr(Stdio::null())
        .kill_on_drop(true);
    if let Some(version) = pretend_version {
        cmd.env("VMPANE_TEST_AGENT_VERSION", version);
    }
    cmd.spawn().unwrap()
}

async fn wait_for_session(host: &mut Host, connected: bool) {
    for _ in 0..100 {
        if host.call("agent.info", json!({})).await.unwrap()["session"] == connected {
            return;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    panic!("the session helper never became connected={connected}");
}

#[tokio::test]
async fn user_execs_run_in_the_session_helper() {
    let mut host = Host::start_with_sessions().await;
    assert_eq!(
        host.call("exec.start", json!({"argv": ["id", "-u"]}))
            .await
            .unwrap_err()
            .0,
        -32048
    );
    let dir = host.dir.clone();
    let mut helper = session_helper(&dir, None);
    wait_for_session(&mut host, true).await;
    let caps = host.call("agent.info", json!({})).await.unwrap()["caps"].clone();
    assert!(caps.as_array().unwrap().contains(&json!("reveal")));

    let me = nix::unistd::getuid().as_raw().to_string();
    let (out, _, exited) = host.exec(json!({"shell": "id -u; exit 5"})).await;
    assert_eq!(String::from_utf8(out).unwrap().trim(), me);
    assert_eq!(exited["code"], 5);

    // stdin relayed through the daemon to the helper's process.
    let started = host
        .call("exec.start", json!({"argv": ["/bin/cat"], "stdin": true}))
        .await
        .unwrap();
    let stdin = started["stdin"].as_u64().unwrap() as u32;
    host.send_frame(Frame::Chunk {
        stream: stdin,
        data: Bytes::from_static(b"through two hops"),
    })
    .await;
    host.send_frame(Frame::End {
        stream: stdin,
        status: StreamStatus::Ok,
    })
    .await;
    let exited = host.exited(started["execId"].as_u64().unwrap()).await;
    assert_eq!(exited["code"], 0);
    let stdout = started["stdout"].as_u64().unwrap() as u32;
    assert_eq!(host.streams.remove(&stdout).unwrap(), b"through two hops");

    // A signal reaches the helper's process.
    let running = host
        .call("exec.start", json!({"argv": ["/bin/sleep", "30"]}))
        .await
        .unwrap();
    let exec_id = running["execId"].as_u64().unwrap();
    host.call("exec.signal", json!({"execId": exec_id, "signal": "term"}))
        .await
        .unwrap();
    assert_eq!(host.exited(exec_id).await["signal"], "SIGTERM");

    // A helper of another version is refused and exits (its service manager would start the installed one);
    // the connected helper stays.
    let mut stale = session_helper(&dir, Some("0.0.0-old"));
    let status = tokio::time::timeout(Duration::from_secs(10), stale.wait())
        .await
        .unwrap()
        .unwrap();
    assert!(status.success());
    assert_eq!(
        host.call("agent.info", json!({})).await.unwrap()["session"],
        true
    );

    // The helper going away ends its user execs and the session.
    let orphan = host
        .call("exec.start", json!({"argv": ["/bin/sleep", "30"]}))
        .await
        .unwrap();
    helper.kill().await.unwrap();
    let exited = host.exited(orphan["execId"].as_u64().unwrap()).await;
    assert_eq!(exited["signal"], "disconnected");
    wait_for_session(&mut host, false).await;
}

/// macOS guests: the clipboard through the daemon and the session helper, on a private named pasteboard.
#[cfg(target_os = "macos")]
#[tokio::test]
async fn clipboard_round_trips_through_the_session_helper() {
    let mut host = Host::start_with_sessions().await;
    let dir = host.dir.clone();
    let board = format!("app.vmpane.test.{}", std::process::id());
    let mut cmd = tokio::process::Command::new(env!("CARGO_BIN_EXE_vmpane-agent"));
    cmd.args([
        "session",
        "--socket",
        &dir.join("session.sock").display().to_string(),
        "--once",
    ])
    .env("VMPANE_TEST_PASTEBOARD", &board)
    .stderr(Stdio::null())
    .kill_on_drop(true);
    let _helper = cmd.spawn().unwrap();
    wait_for_session(&mut host, true).await;
    let caps = host.call("agent.info", json!({})).await.unwrap()["caps"].clone();
    assert!(caps.as_array().unwrap().contains(&json!("clipboard")));

    // Set text and a file list; the text travels on a host stream.
    let text = "clipboard é😀 through two hops";
    let id = host
        .request(
            "clipboard.set",
            json!({"items": [
                {"type": "text", "stream": 1, "size": text.len()},
                {"type": "files", "files": ["/tmp/a.txt", "/tmp/b c.txt"]},
            ]}),
        )
        .await;
    host.send_frame(Frame::Chunk {
        stream: 1,
        data: Bytes::copy_from_slice(text.as_bytes()),
    })
    .await;
    host.send_frame(Frame::End {
        stream: 1,
        status: StreamStatus::Ok,
    })
    .await;
    host.response(id).await.unwrap();

    let got = host
        .call("clipboard.get", json!({"types": ["text", "files", "png"]}))
        .await
        .unwrap();
    let items = got["items"].as_array().unwrap();
    let text_item = items.iter().find(|i| i["type"] == "text").unwrap();
    let stream = text_item["stream"].as_u64().unwrap() as u32;
    assert_eq!(stream % 2, 0);
    assert_eq!(host.until_ended(stream).await, StreamStatus::Ok);
    assert_eq!(host.streams.remove(&stream).unwrap(), text.as_bytes());
    let files = items.iter().find(|i| i["type"] == "files").unwrap();
    assert_eq!(files["files"], json!(["/tmp/a.txt", "/tmp/b c.txt"]));
    assert!(items.iter().all(|i| i["type"] != "png"));

    // A change by someone else is reported; our own set was not.
    assert!(
        !host
            .notifications
            .iter()
            .any(|(m, _)| m == "clipboard.changed")
    );
    let script = format!(
        "import AppKit; let pb = NSPasteboard(name: NSPasteboard.Name(\"{board}\")); pb.clearContents(); pb.setString(\"from elsewhere\", forType: .string)"
    );
    let status = std::process::Command::new("/usr/bin/swift")
        .args(["-e", &script])
        .status()
        .unwrap();
    assert!(status.success());
    for _ in 0..40 {
        if host
            .notifications
            .iter()
            .any(|(m, p)| m == "clipboard.changed" && p["types"] == json!(["text"]))
        {
            return;
        }
        let _ =
            tokio::time::timeout(Duration::from_millis(250), host.next_frame_into_state()).await;
    }
    panic!("no clipboard.changed after an outside change");
}

/// What a host sends when a QEMU port's guest kept an earlier session (QEMU started again under a guest restored from
/// saved memory): an answer to no request. The agent ends that session and says `hello` again on a new connection.
#[tokio::test]
async fn an_answer_to_no_request_starts_a_new_session() {
    let dir = scratch();
    let socket = dir.join("s");
    let listener = UnixListener::bind(&socket).unwrap();
    let mut child = tokio::process::Command::new(env!("CARGO_BIN_EXE_vmpane-agent"))
        .args(["--connect", &format!("unix:{}", socket.display())])
        .stderr(Stdio::null())
        .kill_on_drop(true)
        .spawn()
        .unwrap();
    async fn accept_hello(listener: &UnixListener) -> tokio::net::UnixStream {
        let (mut stream, _) = tokio::time::timeout(Duration::from_secs(10), listener.accept())
            .await
            .expect("the agent connects")
            .unwrap();
        let (mut decoder, mut buf) = (FrameDecoder::new(), BytesMut::new());
        loop {
            if let Some(Frame::Message(bytes)) = decoder.decode(&mut buf).unwrap() {
                let Message::Request(hello) = Message::parse(&bytes).unwrap() else {
                    panic!("expected hello")
                };
                assert_eq!(hello.method, "hello");
                let reply: Message =
                    Response::ok(hello.id, &json!({"proto": 1, "hostVersion": "test"})).into();
                let frame = Frame::Message(reply.to_bytes().unwrap().into());
                stream.write_all(&frame.to_bytes().unwrap()).await.unwrap();
                return stream;
            }
            assert!(
                stream.read_buf(&mut buf).await.unwrap() > 0,
                "closed before hello"
            );
        }
    }
    let mut first = accept_hello(&listener).await;
    let stray = br#"{"jsonrpc":"2.0","id":0,"error":{"code":-32600,"message":"a new host connection: say hello first"}}"#;
    let frame = Frame::Message(Bytes::from_static(stray));
    first.write_all(&frame.to_bytes().unwrap()).await.unwrap();
    let mut rest = Vec::new();
    tokio::time::timeout(Duration::from_secs(10), first.read_to_end(&mut rest))
        .await
        .expect("the agent ends the session")
        .unwrap();
    drop(accept_hello(&listener).await);
    let _ = child.start_kill();
    let _ = std::fs::remove_dir_all(&dir);
}
