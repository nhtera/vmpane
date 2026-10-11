//! The daemon's end of the user-session helper (`vmpane-agent session`): the daemon listens on a Unix socket,
//! the helper dials it and speaks the same protocol as the agent does to the host, with the daemon in the
//! host's role. Requests that must run as the logged-in user (`exec.start {as: "user"}`, `session.reveal`) are
//! relayed to the current helper.
//!
//! Who may connect: the socket is world-writable, so the peer's uid is checked against the user of the active
//! console session (logind on Linux, the owner of /dev/console on macOS). The helper must be the daemon's own
//! version: on a mismatch (the guest tools were updated) the daemon refuses its `hello`, the helper exits, and
//! its service manager starts the new binary.

use std::collections::HashMap;
#[cfg(unix)]
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use bytes::{Bytes, BytesMut};
use serde_json::Value;
use tokio::io::{AsyncRead, AsyncWrite};
use tokio::sync::{mpsc, oneshot};
use vmpane_agent_proto::PROTO;
use vmpane_agent_proto::error::ErrorCode;
use vmpane_agent_proto::frame::{Frame, FrameDecoder, StreamStatus, is_host_stream};
use vmpane_agent_proto::jsonrpc::{ErrorObject, Id, Message, Request, Response, encode_value};
use vmpane_agent_proto::limits::MAX_OPEN_STREAMS;
use vmpane_agent_proto::methods::{ExecExited, HelloParams, HelloResult, method};

use crate::connection::{Incoming, Outbox, next_frame, read_message, spawn_writer};

/// Calls to the helper wait this long for their response.
const CALL_TIMEOUT: Duration = Duration::from_secs(30);

/// Which ids of a result name guest → daemon streams.
pub type StreamNames = fn(&Value) -> Vec<u32>;

/// A result and the streams it named, ready to read.
pub type CallResult = (Value, HashMap<u32, mpsc::Receiver<Incoming>>);

type Reply = oneshot::Sender<Result<CallResult, ErrorObject>>;

#[derive(Default)]
struct LinkState {
    next_id: i64,
    pending: HashMap<i64, (StreamNames, Reply)>,
    inbound: HashMap<u32, mpsc::Sender<Incoming>>,
    exit_waiters: HashMap<u32, oneshot::Sender<ExecExited>>,
    early_exits: HashMap<u32, ExecExited>,
    closed: bool,
}

/// One connected session helper.
pub struct SessionLink {
    out: Outbox,
    state: Mutex<LinkState>,
}

impl SessionLink {
    fn state(&self) -> std::sync::MutexGuard<'_, LinkState> {
        self.state.lock().unwrap_or_else(|p| p.into_inner())
    }

    /// Sends a request and waits for its response; streams the result names are registered before their data
    /// is read.
    pub async fn call(
        &self,
        name: &str,
        params: Value,
        names: StreamNames,
    ) -> Result<CallResult, ErrorObject> {
        let (tx, rx) = oneshot::channel();
        let id = {
            let mut state = self.state();
            if state.closed {
                return Err(gone());
            }
            state.next_id += 1;
            let id = state.next_id;
            state.pending.insert(id, (names, tx));
            id
        };
        let request = Request {
            id: Id::Int(id),
            method: name.to_owned(),
            params: Some(params),
        };
        if self.out.message(request).await.is_err() {
            self.state().pending.remove(&id);
            return Err(gone());
        }
        match tokio::time::timeout(CALL_TIMEOUT, rx).await {
            Ok(Ok(result)) => result,
            Ok(Err(_)) => Err(gone()),
            Err(_) => {
                self.state().pending.remove(&id);
                Err(ErrorObject::new(
                    ErrorCode::Timeout,
                    "the session helper did not answer",
                ))
            }
        }
    }

    pub async fn send(&self, stream: u32, data: Bytes) -> bool {
        self.out.chunk(stream, data).await.is_ok()
    }

    pub async fn end(&self, stream: u32, status: StreamStatus) {
        let _ = self.out.end(stream, status).await;
    }

    /// The helper's `exec.exited` for its exec `exec_id`; None when the helper went away first.
    pub async fn exited(&self, exec_id: u32) -> Option<ExecExited> {
        let rx = {
            let mut state = self.state();
            if let Some(exited) = state.early_exits.remove(&exec_id) {
                return Some(exited);
            }
            if state.closed {
                return None;
            }
            let (tx, rx) = oneshot::channel();
            state.exit_waiters.insert(exec_id, tx);
            rx
        };
        rx.await.ok()
    }

    fn close(&self) {
        let mut state = self.state();
        state.closed = true;
        for (_, (_, reply)) in state.pending.drain() {
            let _ = reply.send(Err(gone()));
        }
        state.inbound.clear();
        state.exit_waiters.clear();
    }

    fn settle(&self, response: Response) -> Result<(), String> {
        let Some(Id::Int(id)) = response.id else {
            return Err("response without an integer id".into());
        };
        let Some((names, reply)) = self.state().pending.remove(&id) else {
            return Ok(()); // a call that timed out; its streams are unknown and get dropped
        };
        let outcome = match response.outcome {
            Err(err) => Err(err),
            Ok(value) => {
                let ids = names(&value);
                let mut state = self.state();
                if ids
                    .iter()
                    .any(|id| *id == 0 || is_host_stream(*id) || state.inbound.contains_key(id))
                    || state.inbound.len() + ids.len() > MAX_OPEN_STREAMS
                {
                    return Err("bad stream ids in a response".into());
                }
                let mut streams = HashMap::new();
                for id in ids {
                    let (tx, rx) = mpsc::channel(16);
                    state.inbound.insert(id, tx);
                    streams.insert(id, rx);
                }
                Ok((value, streams))
            }
        };
        let _ = reply.send(outcome);
        Ok(())
    }

    fn note_exit(&self, exited: ExecExited) {
        let mut state = self.state();
        if let Some(waiter) = state.exit_waiters.remove(&exited.exec_id) {
            let _ = waiter.send(exited);
        } else if state.early_exits.len() < 1024 {
            state.early_exits.insert(exited.exec_id, exited);
        }
    }

    async fn route(&self, stream: u32, item: Incoming) -> Result<(), String> {
        let ends = matches!(item, Incoming::End(_));
        let tx = {
            let mut state = self.state();
            if ends {
                state.inbound.remove(&stream)
            } else {
                state.inbound.get(&stream).cloned()
            }
        };
        let Some(tx) = tx else {
            return Err(format!("data on unknown stream {stream}"));
        };
        if tx.send(item).await.is_err() {
            self.state().inbound.remove(&stream);
        }
        Ok(())
    }
}

fn gone() -> ErrorObject {
    ErrorObject::new(ErrorCode::NoSession, "the user session helper went away")
}

/// The current session helper, if one is connected.
#[derive(Default)]
pub struct SessionHub {
    current: Mutex<Option<Arc<SessionLink>>>,
}

impl SessionHub {
    pub fn current(&self) -> Option<Arc<SessionLink>> {
        self.current
            .lock()
            .unwrap_or_else(|p| p.into_inner())
            .clone()
    }

    pub fn connected(&self) -> bool {
        self.current().is_some()
    }

    fn set(&self, link: Option<Arc<SessionLink>>) {
        *self.current.lock().unwrap_or_else(|p| p.into_inner()) = link;
    }

    /// Listens on `path` for helpers. `allowed_uid` overrides the console-user check (tests).
    #[cfg(unix)]
    pub async fn listen(self: Arc<Self>, path: PathBuf, allowed_uid: Option<u32>) {
        let listener = match bind(&path) {
            Ok(listener) => listener,
            Err(err) => {
                tracing::error!(path = %path.display(), %err, "cannot listen for the session helper");
                return;
            }
        };
        loop {
            let Ok((stream, _)) = listener.accept().await else {
                continue;
            };
            let Ok(cred) = stream.peer_cred() else {
                continue;
            };
            let uid = cred.uid();
            let permitted = match allowed_uid {
                Some(allowed) => uid == allowed,
                None => crate::os::is_console_user(uid),
            };
            if !permitted {
                tracing::warn!(
                    uid,
                    "refused a session helper that is not the console user's"
                );
                continue;
            }
            let hub = Arc::clone(&self);
            tokio::spawn(async move {
                tracing::info!(uid, "session helper connecting");
                hub.serve(stream).await
            });
        }
    }

    /// Runs one helper connection (already admitted) through `hello` to its end.
    pub async fn serve<S: AsyncRead + AsyncWrite + Send + 'static>(self: Arc<Self>, stream: S) {
        let (mut reader, writer) = tokio::io::split(stream);
        let writer = spawn_writer(writer);
        let link = Arc::new(SessionLink {
            out: writer.out.clone(),
            state: Mutex::default(),
        });
        let mut decoder = FrameDecoder::new();
        let mut buf = BytesMut::new();
        let accepted = tokio::time::timeout(
            Duration::from_secs(10),
            read_message(&mut reader, &mut decoder, &mut buf),
        )
        .await;
        let Ok(Ok(Message::Request(hello))) = accepted else {
            return;
        };
        if hello.method != method::HELLO {
            return;
        }
        let version = env!("CARGO_PKG_VERSION");
        let refusal = match hello.decode_params::<HelloParams>() {
            Ok(params) if params.agent_version == version => None,
            Ok(params) => Some(format!(
                "helper {} is not daemon {version}; restart it",
                params.agent_version
            )),
            Err(err) => Some(err.message),
        };
        if let Some(reason) = refusal {
            tracing::info!(%reason, "refusing a session helper");
            let error = ErrorObject::new(ErrorCode::ProtoUnsupported, reason);
            let _ = link
                .out
                .message(Response::error(Some(hello.id), error))
                .await;
            drop(link);
            let _ = writer.task.await;
            return;
        }
        let result = HelloResult {
            proto: PROTO,
            host_version: version.to_owned(),
        };
        if link
            .out
            .message(Response::ok(hello.id, &result))
            .await
            .is_err()
        {
            return;
        }
        tracing::info!("session helper connected");
        self.set(Some(Arc::clone(&link)));
        let outcome = read_loop(&link, &mut reader, &mut decoder, &mut buf).await;
        link.close();
        writer.task.abort();
        let mut current = self.current.lock().unwrap_or_else(|p| p.into_inner());
        if current.as_ref().is_some_and(|c| Arc::ptr_eq(c, &link)) {
            *current = None;
        }
        tracing::info!(?outcome, "session helper disconnected");
    }
}

#[cfg(unix)]
fn bind(path: &Path) -> std::io::Result<tokio::net::UnixListener> {
    use std::os::unix::fs::PermissionsExt;
    // A stale socket from an earlier daemon is in the way; nothing else should be at this path.
    if let Ok(meta) = std::fs::symlink_metadata(path) {
        use std::os::unix::fs::FileTypeExt;
        if meta.file_type().is_socket() {
            std::fs::remove_file(path)?;
        }
    }
    let listener = tokio::net::UnixListener::bind(path)?;
    // Any local user may connect; the peer check decides who stays.
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o666))?;
    Ok(listener)
}

async fn read_loop<R: AsyncRead + Unpin>(
    link: &SessionLink,
    reader: &mut R,
    decoder: &mut FrameDecoder,
    buf: &mut BytesMut,
) -> Result<(), String> {
    loop {
        let frame = match next_frame(reader, decoder, buf).await {
            Ok(Some(frame)) => frame,
            Ok(None) => return Ok(()),
            Err(err) => return Err(err.to_string()),
        };
        match frame {
            Frame::Message(bytes) => match Message::parse(&bytes).map_err(|e| e.to_string())? {
                Message::Response(response) => link.settle(response)?,
                Message::Notification(n) if n.method == method::EXEC_EXITED => {
                    if let Ok(exited) = n.decode_params::<ExecExited>() {
                        link.note_exit(exited);
                    }
                }
                Message::Notification(_) => {}
                Message::Request(r) => return Err(format!("the helper may not send {}", r.method)),
            },
            Frame::Chunk { stream, data } => link.route(stream, Incoming::Data(data)).await?,
            Frame::End { stream, status } => link.route(stream, Incoming::End(status)).await?,
        }
    }
}

/// Params for relaying a request: the same object, re-encoded (it was already validated by the caller).
pub fn relay_params<T: serde::Serialize>(params: &T) -> Value {
    encode_value(params)
}

#[cfg(windows)]
impl SessionHub {
    /// Keeps a helper running as the user at the console (Windows service only): launched into that session
    /// with a fresh named pipe whose only accepted client is the launched process. Session changes (logon,
    /// logoff, console switch) end the current helper and start over.
    pub async fn supervise(self: Arc<Self>, mut changes: mpsc::UnboundedReceiver<()>) {
        use tokio::net::windows::named_pipe::ServerOptions;

        use crate::os::session;

        let Ok(exe) = std::env::current_exe() else {
            return;
        };
        let mut attempt = 0u64;
        loop {
            let Some(console) = session::console_session() else {
                pause_or_change(&mut changes).await;
                continue;
            };
            attempt += 1;
            let pipe = format!(r"\\.\pipe\vmpane-agent-{}-{attempt}", std::process::id());
            let server = match ServerOptions::new()
                .first_pipe_instance(true)
                .reject_remote_clients(true)
                .create(&pipe)
            {
                Ok(server) => server,
                Err(err) => {
                    tracing::warn!(%err, "cannot create the session helper's pipe");
                    pause_or_change(&mut changes).await;
                    continue;
                }
            };
            let helper = match session::launch(console, &exe, &pipe) {
                Ok(helper) => Arc::new(helper),
                Err(err) => {
                    // No user logged in to the console session yet: try again on the next session change.
                    tracing::debug!(%err, console, "cannot start the session helper");
                    pause_or_change(&mut changes).await;
                    continue;
                }
            };
            let connected = tokio::select! {
                result = tokio::time::timeout(Duration::from_secs(30), server.connect()) => matches!(result, Ok(Ok(()))),
                _ = changes.recv() => false,
            };
            if connected && session::pipe_client_pid(&server) == Some(helper.pid) {
                let exited = {
                    let helper = Arc::clone(&helper);
                    tokio::task::spawn_blocking(move || helper.wait())
                };
                tokio::select! {
                    () = Arc::clone(&self).serve(server) => {}
                    _ = changes.recv() => {}
                    _ = exited => {}
                }
                self.set(None);
            } else if connected {
                tracing::warn!("a process other than the launched helper took the session pipe");
            }
            helper.kill();
            tokio::time::sleep(Duration::from_secs(2)).await;
        }
    }
}

/// Five seconds, or less if the session changes.
#[cfg(windows)]
async fn pause_or_change(changes: &mut mpsc::UnboundedReceiver<()>) {
    tokio::select! {
        () = tokio::time::sleep(Duration::from_secs(5)) => {}
        _ = changes.recv() => {}
    }
}
