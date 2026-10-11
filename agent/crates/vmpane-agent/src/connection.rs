//! One connection to the host: `hello` first, then host requests handled concurrently, with data streams
//! multiplexed over the same frames.
//!
//! Ordering: everything leaves through one ordered queue ([`Outbox`]), so a response that names a stream is
//! always sent before the stream's first chunk (handlers return the streaming work as [`Reply::then`]).
//! Chunks for a host stream nobody waits for (a push the agent already refused) are dropped.

use std::collections::{HashMap, HashSet};
use std::future::Future;
use std::pin::Pin;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use bytes::{Bytes, BytesMut};
use serde::Serialize;
use serde_json::Value;
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};
use tokio::sync::mpsc;
use tokio::task::JoinSet;
use vmpane_agent_proto::error::ErrorCode;
use vmpane_agent_proto::frame::{Frame, FrameDecoder, StreamStatus, is_host_stream};
use vmpane_agent_proto::jsonrpc::{
    ErrorObject, Id, Message, Notification, Request, Response, encode_value,
};
use vmpane_agent_proto::limits::{HEARTBEAT_SECONDS, MAX_CHUNK, MAX_OPEN_STREAMS};
use vmpane_agent_proto::methods::Empty;
use vmpane_agent_proto::methods::{HelloParams, HelloResult, method};
use vmpane_agent_proto::{MIN_PROTO, PROTO};

use crate::agent::{Agent, Role};
use crate::transport::BoxIo;
use crate::{dispatch, exec};

/// How long the host has to answer `hello`.
const HELLO_TIMEOUT: Duration = Duration::from_secs(10);
/// Frames queued for the writer before senders wait (backpressure from a slow host).
const OUTBOX_DEPTH: usize = 64;
/// Chunks queued per incoming stream before the reader waits for the consumer.
const INCOMING_DEPTH: usize = 16;

#[derive(Debug)]
pub enum ConnError {
    Io(std::io::Error),
    /// The host broke the protocol; the connection is dropped.
    Protocol(String),
    /// The host refused `hello`.
    Refused(ErrorObject),
}

impl std::fmt::Display for ConnError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ConnError::Io(err) => write!(f, "I/O: {err}"),
            ConnError::Protocol(why) => write!(f, "protocol violation: {why}"),
            ConnError::Refused(err) => write!(f, "hello refused ({}): {}", err.code, err.message),
        }
    }
}

impl From<std::io::Error> for ConnError {
    fn from(err: std::io::Error) -> ConnError {
        ConnError::Io(err)
    }
}

/// The connection is gone; whatever was being sent is lost.
#[derive(Debug, Clone, Copy)]
pub struct Closed;

/// The ordered queue of frames to the host.
#[derive(Clone)]
pub struct Outbox(mpsc::Sender<Frame>);

impl Outbox {
    pub async fn message(&self, message: impl Into<Message>) -> Result<(), Closed> {
        let message = message.into();
        let bytes = match message.to_bytes() {
            Ok(bytes) if bytes.len() <= vmpane_agent_proto::limits::MAX_JSON_FRAME => bytes,
            _ => {
                // A result too large for one frame (or with an over-long string) becomes an error response.
                let Message::Response(Response { id, .. }) = message else {
                    tracing::warn!("dropping an oversized notification");
                    return Ok(());
                };
                let err = ErrorObject::new(ErrorCode::TooLarge, "result exceeds the message limit");
                Message::Response(Response::error(id, err))
                    .to_bytes()
                    .map_err(|_| Closed)?
            }
        };
        self.0
            .send(Frame::Message(bytes.into()))
            .await
            .map_err(|_| Closed)
    }

    pub async fn notify<T: Serialize>(&self, name: &str, params: &T) -> Result<(), Closed> {
        self.message(vmpane_agent_proto::jsonrpc::Notification::new(name, params))
            .await
    }

    /// Sends `data` on `stream`, split into chunks no larger than the limit.
    pub async fn chunk(&self, stream: u32, mut data: Bytes) -> Result<(), Closed> {
        while !data.is_empty() {
            let piece = data.split_to(data.len().min(MAX_CHUNK));
            self.0
                .send(Frame::Chunk {
                    stream,
                    data: piece,
                })
                .await
                .map_err(|_| Closed)?;
        }
        Ok(())
    }

    pub async fn end(&self, stream: u32, status: StreamStatus) -> Result<(), Closed> {
        self.0
            .send(Frame::End { stream, status })
            .await
            .map_err(|_| Closed)
    }
}

/// Data arriving on a stream the host writes to.
#[derive(Debug)]
pub enum Incoming {
    Data(Bytes),
    End(StreamStatus),
}

/// Open streams of one connection, both directions; at most [`MAX_OPEN_STREAMS`] together.
#[derive(Default)]
struct StreamTable {
    incoming: HashMap<u32, mpsc::Sender<Incoming>>,
    outgoing: HashSet<u32>,
    next_guest: u32,
}

impl StreamTable {
    fn check_room(&self) -> Result<(), ErrorObject> {
        if self.incoming.len() + self.outgoing.len() >= MAX_OPEN_STREAMS {
            return Err(ErrorObject::new(ErrorCode::Busy, "too many open streams"));
        }
        Ok(())
    }

    fn next_id(&mut self) -> u32 {
        loop {
            self.next_guest = self.next_guest.wrapping_add(2).max(2);
            let id = self.next_guest;
            if !self.incoming.contains_key(&id) && !self.outgoing.contains(&id) {
                return id;
            }
        }
    }
}

/// The work a handler leaves for after its response is queued: streaming data, waiting for a process.
pub type Then = Pin<Box<dyn Future<Output = ()> + Send>>;

pub struct Reply {
    pub result: Value,
    pub then: Option<Then>,
}

impl Reply {
    pub fn ok<T: Serialize>(result: &T) -> Result<Reply, ErrorObject> {
        Ok(Reply {
            result: encode_value(result),
            then: None,
        })
    }

    pub fn then<T: Serialize>(
        result: &T,
        then: impl Future<Output = ()> + Send + 'static,
    ) -> Result<Reply, ErrorObject> {
        Ok(Reply {
            result: encode_value(result),
            then: Some(Box::pin(then)),
        })
    }
}

/// State of one live connection.
pub struct Conn {
    pub agent: Arc<Agent>,
    pub out: Outbox,
    pub proto: u32,
    streams: Mutex<StreamTable>,
    pub execs: exec::Registry,
}

impl Conn {
    fn table(&self) -> std::sync::MutexGuard<'_, StreamTable> {
        // A panic while holding the lock leaves only plain maps behind; keep using them.
        self.streams
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    /// Accepts a host-allocated stream named in a request (`file.push`, `clipboard.set`).
    pub fn accept_host_stream(&self, id: u32) -> Result<mpsc::Receiver<Incoming>, ErrorObject> {
        let mut table = self.table();
        if !is_host_stream(id) || table.incoming.contains_key(&id) {
            return Err(ErrorObject::new(
                ErrorCode::InvalidParams,
                format!("stream {id} is not a free host stream id"),
            ));
        }
        table.check_room()?;
        let (tx, rx) = mpsc::channel(INCOMING_DEPTH);
        table.incoming.insert(id, tx);
        Ok(rx)
    }

    /// A guest-allocated stream the host writes to (exec stdin).
    pub fn open_inbound(&self) -> Result<(u32, mpsc::Receiver<Incoming>), ErrorObject> {
        let mut table = self.table();
        table.check_room()?;
        let id = table.next_id();
        let (tx, rx) = mpsc::channel(INCOMING_DEPTH);
        table.incoming.insert(id, tx);
        Ok((id, rx))
    }

    /// A guest-allocated stream the agent writes to. Finish it with [`OutStream::finish`].
    pub fn open_outbound(self: &Arc<Self>) -> Result<OutStream, ErrorObject> {
        let mut table = self.table();
        table.check_room()?;
        let id = table.next_id();
        table.outgoing.insert(id);
        Ok(OutStream {
            id,
            conn: Arc::clone(self),
            finished: false,
        })
    }

    /// Stops routing an incoming stream (its consumer is done or gone).
    pub fn close_inbound(&self, id: u32) {
        self.table().incoming.remove(&id);
    }

    async fn route(&self, stream: u32, item: Incoming) {
        let ends = matches!(item, Incoming::End(_));
        let tx = if ends {
            self.table().incoming.remove(&stream)
        } else {
            self.table().incoming.get(&stream).cloned()
        };
        match tx {
            Some(tx) => {
                if tx.send(item).await.is_err() {
                    self.close_inbound(stream);
                }
            }
            None => tracing::debug!(stream, "data for a stream nobody reads; dropped"),
        }
    }
}

/// A stream from the agent to the host.
pub struct OutStream {
    pub id: u32,
    conn: Arc<Conn>,
    finished: bool,
}

impl OutStream {
    pub async fn send(&self, data: Bytes) -> Result<(), Closed> {
        self.conn.out.chunk(self.id, data).await
    }

    pub async fn finish(mut self, status: StreamStatus) -> Result<(), Closed> {
        self.finished = true;
        self.conn.table().outgoing.remove(&self.id);
        self.conn.out.end(self.id, status).await
    }
}

impl Drop for OutStream {
    fn drop(&mut self) {
        if !self.finished {
            self.conn.table().outgoing.remove(&self.id);
            // Best effort: the host learns the stream was cancelled if the queue has room.
            let _ = self.conn.out.0.try_send(Frame::End {
                stream: self.id,
                status: StreamStatus::Cancelled,
            });
        }
    }
}

/// The writing half of a connection: an ordered queue drained by one task, which records when a write started
/// (for the heartbeat's "stuck write" check).
pub struct Writer {
    pub out: Outbox,
    pub task: tokio::task::JoinHandle<std::io::Result<()>>,
    pub epoch: Instant,
    pub busy_since: Arc<AtomicU64>,
}

pub fn spawn_writer<W: AsyncWrite + Unpin + Send + 'static>(mut writer: W) -> Writer {
    let (tx, mut rx) = mpsc::channel::<Frame>(OUTBOX_DEPTH);
    // Milliseconds since `epoch` at which the write in progress started; 0 while the writer is idle.
    let epoch = Instant::now();
    let busy_since = Arc::new(AtomicU64::new(0));
    let writer_busy = Arc::clone(&busy_since);
    let task = tokio::spawn(async move {
        let mut buf = BytesMut::new();
        while let Some(frame) = rx.recv().await {
            buf.clear();
            if frame.encode(&mut buf).is_err() {
                continue;
            }
            // Batch whatever else is queued into the same write.
            while let Ok(next) = rx.try_recv() {
                let _ = next.encode(&mut buf);
                if buf.len() > 4 * MAX_CHUNK {
                    break;
                }
            }
            writer_busy.store(millis_since(epoch).max(1), Ordering::Relaxed);
            writer.write_all(&buf).await?;
            writer.flush().await?;
            writer_busy.store(0, Ordering::Relaxed);
        }
        Ok::<(), std::io::Error>(())
    });
    Writer {
        out: Outbox(tx),
        task,
        epoch,
        busy_since,
    }
}

/// Runs one connection until it ends. `token` goes into `hello` (TCP only).
pub async fn run(agent: Arc<Agent>, io: BoxIo, token: Option<String>) -> Result<(), ConnError> {
    let (mut reader, writer) = tokio::io::split(io);
    let Writer {
        out,
        task: mut writer_task,
        epoch,
        busy_since,
    } = spawn_writer(writer);

    let mut decoder = FrameDecoder::new();
    let mut buf = BytesMut::with_capacity(64 << 10);
    let hello = HelloParams {
        proto: PROTO,
        min_proto: MIN_PROTO,
        agent_version: agent.version.clone(),
        os: agent.identity.os.clone(),
        arch: agent.identity.arch.clone(),
        os_version: agent.identity.os_version.clone(),
        caps: agent.caps(),
        session: agent.session_connected(),
        token,
    };
    out.message(Request::new(Id::Int(1), method::HELLO, &hello))
        .await
        .map_err(|_| closed())?;
    let reply = tokio::time::timeout(
        HELLO_TIMEOUT,
        read_message(&mut reader, &mut decoder, &mut buf),
    )
    .await
    .map_err(|_| ConnError::Protocol("no answer to hello".into()))??;
    let result: HelloResult = match reply {
        Message::Response(r) if r.id == Some(Id::Int(1)) => {
            r.decode_result().map_err(ConnError::Refused)?
        }
        _ => return Err(ConnError::Protocol("expected the answer to hello".into())),
    };
    if vmpane_agent_proto::negotiate((MIN_PROTO, PROTO), (result.proto, result.proto)).is_none() {
        return Err(ConnError::Protocol(format!(
            "host chose proto {} outside {MIN_PROTO}..={PROTO}",
            result.proto
        )));
    }
    tracing::info!(proto = result.proto, host = %result.host_version, "connected");

    let conn = Arc::new(Conn {
        agent: Arc::clone(&agent),
        out,
        proto: result.proto,
        streams: Mutex::default(),
        execs: exec::Registry::default(),
    });
    let mut tasks = JoinSet::new();
    // The daemon relays its session helper's notifications here; a session helper watches its clipboard.
    let watcher = match agent.role {
        Role::Daemon => {
            agent.session.set_host(Some(conn.out.clone()));
            None
        }
        Role::Session => crate::clipboard::watch(&conn),
    };
    let heartbeat = heartbeat(conn.out.clone(), epoch, busy_since);
    tokio::pin!(heartbeat);
    let outcome = loop {
        tokio::select! {
            frame = next_frame(&mut reader, &mut decoder, &mut buf) => match frame {
                Ok(Some(frame)) => {
                    if let Err(err) = handle_frame(&conn, &mut tasks, frame).await {
                        break Err(err);
                    }
                }
                Ok(None) => break Ok(()),
                Err(err) => break Err(err),
            },
            Some(_) = tasks.join_next(), if !tasks.is_empty() => {}
            () = &mut heartbeat => break Err(ConnError::Protocol("the connection stopped taking writes".into())),
            done = &mut writer_task => {
                break match done {
                    Ok(Ok(())) => Ok(()),
                    Ok(Err(err)) => Err(err.into()),
                    Err(err) => Err(ConnError::Protocol(format!("writer failed: {err}"))),
                };
            }
        }
    };
    tasks.abort_all();
    if let Some(watcher) = watcher {
        watcher.abort();
    }
    if agent.role == Role::Daemon {
        agent.session.set_host(None);
    }
    conn.execs.kill_all();
    agent.freeze.thaw_on_disconnect().await;
    writer_task.abort();
    outcome
}

/// Queues `agent.heartbeat` every few seconds (skipped while the queue is full: the writer is busy anyway).
/// Returns when a single write has been stuck for three periods: a dead connection the writer cannot finish.
/// A full queue alone is no reason: the host may hold back reading while its client is slow. A write that fails
/// ends the connection through the writer task.
pub async fn heartbeat(out: Outbox, epoch: Instant, busy_since: Arc<AtomicU64>) {
    let period = Duration::from_secs(HEARTBEAT_SECONDS);
    let stuck_after = u64::try_from((3 * period).as_millis()).unwrap_or(u64::MAX);
    loop {
        tokio::time::sleep(period).await;
        let started = busy_since.load(Ordering::Relaxed);
        if started != 0 && millis_since(epoch).saturating_sub(started) > stuck_after {
            return;
        }
        if let Ok(bytes) =
            Message::from(Notification::new(method::AGENT_HEARTBEAT, &Empty {})).to_bytes()
        {
            match out.0.try_send(Frame::Message(bytes.into())) {
                Ok(()) | Err(mpsc::error::TrySendError::Full(_)) => {}
                Err(mpsc::error::TrySendError::Closed(_)) => return,
            }
        }
    }
}

fn millis_since(epoch: Instant) -> u64 {
    u64::try_from(epoch.elapsed().as_millis()).unwrap_or(u64::MAX)
}

pub fn closed() -> ConnError {
    ConnError::Io(std::io::ErrorKind::BrokenPipe.into())
}

async fn handle_frame(
    conn: &Arc<Conn>,
    tasks: &mut JoinSet<()>,
    frame: Frame,
) -> Result<(), ConnError> {
    match frame {
        Frame::Message(bytes) => match Message::parse(&bytes) {
            Ok(Message::Request(request)) => {
                // Streams named in the request are registered now, before the reader moves on to their chunks.
                let inbound = dispatch::accept_streams(conn, &request);
                let conn = Arc::clone(conn);
                tasks.spawn(async move {
                    let id = request.id.clone();
                    let (response, then) = match inbound {
                        Err(err) => (Response::error(Some(id), err), None),
                        Ok(inbound) => match dispatch::handle(&conn, &request, inbound).await {
                            Ok(reply) => (
                                Response {
                                    id: Some(id),
                                    outcome: Ok(reply.result),
                                },
                                reply.then,
                            ),
                            Err(err) => (Response::error(Some(id), err), None),
                        },
                    };
                    if conn.out.message(response).await.is_ok()
                        && let Some(then) = then
                    {
                        then.await;
                    }
                });
                Ok(())
            }
            Ok(Message::Notification(n)) => {
                tracing::debug!(method = %n.method, "ignoring a host notification");
                Ok(())
            }
            Ok(Message::Response(_)) => Err(ConnError::Protocol("unexpected response".into())),
            Err(err) => Err(ConnError::Protocol(format!("bad message: {err}"))),
        },
        Frame::Chunk { stream, data } => {
            conn.route(stream, Incoming::Data(data)).await;
            Ok(())
        }
        Frame::End { stream, status } => {
            conn.route(stream, Incoming::End(status)).await;
            Ok(())
        }
    }
}

pub async fn next_frame<R: AsyncRead + Unpin>(
    reader: &mut R,
    decoder: &mut FrameDecoder,
    buf: &mut BytesMut,
) -> Result<Option<Frame>, ConnError> {
    loop {
        match decoder.decode(buf) {
            Ok(Some(frame)) => return Ok(Some(frame)),
            Ok(None) => {}
            Err(err) => return Err(ConnError::Protocol(format!("bad frame: {err}"))),
        }
        if reader.read_buf(buf).await? == 0 {
            return Ok(None);
        }
    }
}

pub async fn read_message<R: AsyncRead + Unpin>(
    reader: &mut R,
    decoder: &mut FrameDecoder,
    buf: &mut BytesMut,
) -> Result<Message, ConnError> {
    match next_frame(reader, decoder, buf).await? {
        Some(Frame::Message(bytes)) => {
            Message::parse(&bytes).map_err(|err| ConnError::Protocol(format!("bad message: {err}")))
        }
        Some(_) => Err(ConnError::Protocol(
            "stream data before hello completed".into(),
        )),
        None => Err(closed()),
    }
}
