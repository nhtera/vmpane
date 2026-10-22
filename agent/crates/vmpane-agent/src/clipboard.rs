//! `clipboard.get` / `clipboard.set` / `clipboard.changed` (macOS and Windows guests: text, formatted text as
//! HTML and RTF, PNG, file lists).
//! The user-session helper owns the pasteboard (`os::clipboard`); the daemon relays the requests and their
//! streams to it, and its `clipboard.changed` to the host. Linux guests have no agent clipboard (spice-vdagent
//! does text and images).

use std::sync::Arc;

use vmpane_agent_proto::error::ErrorCode;
use vmpane_agent_proto::jsonrpc::ErrorObject;
use vmpane_agent_proto::methods::{ClipboardContents, ClipboardGetParams};

use crate::connection::{Conn, Reply};
use crate::dispatch::Inbound;

/// Whether this OS's agent serves the clipboard.
pub const SUPPORTED: bool = cfg!(any(target_os = "macos", windows));

fn unsupported() -> ErrorObject {
    ErrorObject::new(
        ErrorCode::CapUnsupported,
        "this guest's agent has no clipboard",
    )
}

#[cfg(any(target_os = "macos", windows))]
mod imp {
    use std::sync::Arc;
    use std::sync::atomic::{AtomicIsize, Ordering};
    use std::time::Duration;

    use bytes::Bytes;
    use tokio::sync::mpsc;
    use vmpane_agent_proto::error::ErrorCode;
    use vmpane_agent_proto::frame::StreamStatus;
    use vmpane_agent_proto::jsonrpc::ErrorObject;
    use vmpane_agent_proto::limits::MAX_CLIPBOARD_BYTES;
    use vmpane_agent_proto::methods::{
        ClipboardChanged, ClipboardContents, ClipboardGetParams, ClipboardItem, ClipboardType,
        Empty, method,
    };

    use crate::connection::{Conn, Incoming, Reply};
    use crate::dispatch::Inbound;
    use crate::os::clipboard::{self as pasteboard, Content};
    use crate::session_link::{SessionLink, StreamNames, relay_params};

    /// The change count our own `clipboard.set` produced: not reported back as a change.
    static OWN_CHANGE: AtomicIsize = AtomicIsize::new(-1);

    fn blocking_error(err: tokio::task::JoinError) -> ErrorObject {
        ErrorObject::new(
            ErrorCode::InternalError,
            format!("pasteboard access failed: {err}"),
        )
    }

    /// Session helper: reads the pasteboard; text and PNG go out on streams after the answer.
    pub async fn get(conn: &Arc<Conn>, params: ClipboardGetParams) -> Result<Reply, ErrorObject> {
        let wanted = params.types;
        let found = tokio::task::spawn_blocking(move || {
            wanted
                .into_iter()
                .filter_map(|kind| pasteboard::read(kind).map(|c| (kind, c)))
                .collect::<Vec<_>>()
        })
        .await
        .map_err(blocking_error)?;
        let mut items = Vec::new();
        let mut sends = Vec::new();
        for (kind, content) in found {
            match content {
                Content::Bytes(bytes)
                    if bytes.len() as u64 <= MAX_CLIPBOARD_BYTES && !bytes.is_empty() =>
                {
                    let out = conn.open_outbound()?;
                    items.push(ClipboardItem {
                        kind,
                        stream: Some(out.id),
                        size: Some(bytes.len() as u64),
                        files: Vec::new(),
                    });
                    sends.push((out, bytes));
                }
                Content::Bytes(_) => {} // empty, or over the limit
                Content::Files(files) => items.push(ClipboardItem {
                    kind,
                    stream: None,
                    size: None,
                    files,
                }),
            }
        }
        Reply::then(&ClipboardContents { items }, async move {
            for (out, bytes) in sends {
                if out.send(Bytes::from(bytes)).await.is_ok() {
                    let _ = out.finish(StreamStatus::Ok).await;
                }
            }
        })
    }

    async fn collect(mut rx: mpsc::Receiver<Incoming>) -> Result<Vec<u8>, ErrorObject> {
        let mut data = Vec::new();
        loop {
            match rx.recv().await {
                Some(Incoming::Data(chunk)) => {
                    data.extend_from_slice(&chunk);
                    if data.len() as u64 > MAX_CLIPBOARD_BYTES {
                        return Err(ErrorObject::new(
                            ErrorCode::TooLarge,
                            "clipboard data over 32 MiB",
                        ));
                    }
                }
                Some(Incoming::End(StreamStatus::Ok)) => return Ok(data),
                _ => {
                    return Err(ErrorObject::new(
                        ErrorCode::Integrity,
                        "the clipboard stream ended early",
                    ));
                }
            }
        }
    }

    /// Session helper: replaces the pasteboard's contents once every stream has arrived.
    pub async fn set(
        conn: &Arc<Conn>,
        params: ClipboardContents,
        mut inbound: Inbound,
    ) -> Result<Reply, ErrorObject> {
        let mut items = Vec::new();
        for item in params.items {
            match (item.kind, item.stream) {
                (ClipboardType::Files, _) => {
                    items.push((ClipboardType::Files, Content::Files(item.files)))
                }
                (kind, Some(stream)) => {
                    let rx = inbound.remove(&stream).ok_or_else(|| {
                        ErrorObject::new(ErrorCode::InvalidParams, "unknown stream")
                    })?;
                    let bytes = collect(rx).await;
                    conn.close_inbound(stream);
                    items.push((kind, Content::Bytes(bytes?)));
                }
                (_, None) => {
                    return Err(ErrorObject::new(
                        ErrorCode::InvalidParams,
                        "text, HTML, RTF and PNG need a stream",
                    ));
                }
            }
        }
        let count = tokio::task::spawn_blocking(move || {
            pasteboard::write(items).map(|()| pasteboard::change_count())
        })
        .await
        .map_err(blocking_error)?
        .map_err(|err| ErrorObject::new(ErrorCode::IoError, err.to_string()))?;
        OWN_CHANGE.store(count, Ordering::Relaxed);
        Reply::ok(&Empty {})
    }

    /// Session helper: polls the pasteboard's change count every 250 ms and reports changes (not our own).
    pub fn watch(conn: Arc<Conn>) -> tokio::task::JoinHandle<()> {
        tokio::spawn(async move {
            let mut last = tokio::task::spawn_blocking(pasteboard::change_count)
                .await
                .unwrap_or(0);
            loop {
                tokio::time::sleep(Duration::from_millis(250)).await;
                // Only the change count while nothing changes: asking for the types reads the pasteboard's items.
                let Ok(count) = tokio::task::spawn_blocking(pasteboard::change_count).await else {
                    continue;
                };
                if count == last {
                    continue;
                }
                last = count;
                if count == OWN_CHANGE.load(Ordering::Relaxed) {
                    continue;
                }
                let Ok(types) = tokio::task::spawn_blocking(pasteboard::available).await else {
                    continue;
                };
                let seq = u64::try_from(count).unwrap_or(0);
                if conn
                    .out
                    .notify(method::CLIPBOARD_CHANGED, &ClipboardChanged { types, seq })
                    .await
                    .is_err()
                {
                    return;
                }
            }
        })
    }

    /// Daemon: `clipboard.get` through the helper, its streams relayed under the daemon's ids.
    pub async fn relay_get(
        conn: &Arc<Conn>,
        link: &SessionLink,
        params: ClipboardGetParams,
    ) -> Result<Reply, ErrorObject> {
        let names: StreamNames = |v| {
            v["items"]
                .as_array()
                .into_iter()
                .flatten()
                .filter_map(|item| item["stream"].as_u64())
                .filter_map(|id| u32::try_from(id).ok())
                .collect()
        };
        let (value, mut streams) = link
            .call(method::CLIPBOARD_GET, relay_params(&params), names)
            .await?;
        let mut contents: ClipboardContents = serde_json::from_value(value).map_err(|err| {
            ErrorObject::new(
                ErrorCode::InternalError,
                format!("bad helper result: {err}"),
            )
        })?;
        let mut relays = Vec::new();
        for item in &mut contents.items {
            if let Some(helper_stream) = item.stream {
                let out = conn.open_outbound()?;
                item.stream = Some(out.id);
                relays.push((streams.remove(&helper_stream), out));
            }
        }
        Reply::then(&contents, async move {
            for (helper, out) in relays {
                crate::exec::relay_output(helper, out).await;
            }
        })
    }

    /// Daemon: `clipboard.set` through the helper; the host's streams are copied onto the daemon's own.
    pub async fn relay_set(
        conn: &Arc<Conn>,
        link: &SessionLink,
        mut contents: ClipboardContents,
        mut inbound: Inbound,
    ) -> Result<Reply, ErrorObject> {
        let mut copies: Vec<(Option<mpsc::Receiver<Incoming>>, u32, u32)> = Vec::new();
        for item in &mut contents.items {
            if let Some(host_stream) = item.stream {
                let helper_stream = link.open_outbound();
                item.stream = Some(helper_stream);
                copies.push((inbound.remove(&host_stream), helper_stream, host_stream));
            }
        }
        let pending = link
            .start(method::CLIPBOARD_SET, relay_params(&contents), |_| {
                Vec::new()
            })
            .await?;
        for (rx, helper_stream, host_stream) in copies {
            let mut rx = rx.ok_or_else(|| {
                ErrorObject::new(ErrorCode::InternalError, "stream not registered")
            })?;
            while let Some(item) = rx.recv().await {
                match item {
                    Incoming::Data(data) => {
                        link.send(helper_stream, data).await;
                    }
                    Incoming::End(status) => {
                        link.end(helper_stream, status).await;
                        break;
                    }
                }
            }
            conn.close_inbound(host_stream);
        }
        let (value, _) = link.finish(pending).await?;
        Ok(Reply {
            result: value,
            then: None,
        })
    }
}

/// Session helper: `clipboard.get`.
pub async fn get(conn: &Arc<Conn>, params: ClipboardGetParams) -> Result<Reply, ErrorObject> {
    #[cfg(any(target_os = "macos", windows))]
    {
        imp::get(conn, params).await
    }
    #[cfg(not(any(target_os = "macos", windows)))]
    {
        let _ = (conn, params);
        Err(unsupported())
    }
}

/// Session helper: `clipboard.set`.
pub async fn set(
    conn: &Arc<Conn>,
    params: ClipboardContents,
    inbound: Inbound,
) -> Result<Reply, ErrorObject> {
    #[cfg(any(target_os = "macos", windows))]
    {
        imp::set(conn, params, inbound).await
    }
    #[cfg(not(any(target_os = "macos", windows)))]
    {
        let _ = (conn, params, inbound);
        Err(unsupported())
    }
}

/// Session helper: reports pasteboard changes for the connection's lifetime (macOS, Windows); None elsewhere.
pub fn watch(conn: &Arc<Conn>) -> Option<tokio::task::JoinHandle<()>> {
    #[cfg(any(target_os = "macos", windows))]
    {
        Some(imp::watch(Arc::clone(conn)))
    }
    #[cfg(not(any(target_os = "macos", windows)))]
    {
        let _ = conn;
        None
    }
}

/// Daemon: relays `clipboard.get` / `clipboard.set` to the session helper.
pub async fn relay(
    conn: &Arc<Conn>,
    request: &vmpane_agent_proto::jsonrpc::Request,
    inbound: Inbound,
) -> Result<Reply, ErrorObject> {
    if !SUPPORTED {
        return Err(unsupported());
    }
    let link = conn.agent.session.current().ok_or_else(|| {
        ErrorObject::new(ErrorCode::NoSession, "no user session helper is connected")
    })?;
    #[cfg(any(target_os = "macos", windows))]
    {
        if request.method == vmpane_agent_proto::methods::method::CLIPBOARD_GET {
            imp::relay_get(conn, &link, request.decode_params()?).await
        } else {
            imp::relay_set(conn, &link, request.decode_params()?, inbound).await
        }
    }
    #[cfg(not(any(target_os = "macos", windows)))]
    {
        let _ = (link, request, inbound);
        Err(unsupported())
    }
}
