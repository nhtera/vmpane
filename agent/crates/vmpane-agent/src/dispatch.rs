//! Routes host requests to their handlers, after the cap check.

use std::collections::HashMap;
use std::sync::Arc;

use tokio::sync::mpsc;
use vmpane_agent_proto::error::ErrorCode;
use vmpane_agent_proto::jsonrpc::{ErrorObject, Request};
use vmpane_agent_proto::methods::{
    ClipboardContents, Empty, FilePushParams, PathParams, ScreenElementsParams, SessionStateResult,
    cap, method,
};

use crate::agent::Role;
use crate::connection::{Conn, Incoming, Reply};
use crate::session_link::relay_params;
use crate::{exec, files, netinfo, ports, power, timesync};

/// The cap a method needs, if any.
fn required_cap(name: &str) -> Option<&'static str> {
    Some(match name {
        method::EXEC_START | method::EXEC_SIGNAL => cap::EXEC,
        method::FILE_PUSH | method::FILE_PULL | method::FILE_STAT | method::FILE_MKDIR_TEMP => {
            cap::FILE
        }
        method::SESSION_REVEAL => cap::REVEAL,
        method::DISPLAY_SET => cap::DISPLAY,
        method::TIME_SET => cap::TIME,
        method::POWER_SHUTDOWN => cap::POWER,
        method::NET_ADDRS => cap::NET,
        method::PORTS_LISTENING => cap::PORTS,
        method::FS_FREEZE | method::FS_THAW => cap::FREEZE,
        method::SCREEN_ELEMENTS => cap::SCREEN,
        method::SESSION_STATE => cap::SESSION_STATE,
        _ => return None,
    })
}

/// Streams the host named in a request, by id, registered before the reader moves on to their chunks.
pub type Inbound = HashMap<u32, mpsc::Receiver<Incoming>>;

/// Registers the host streams a request names (`file.push`, `clipboard.set`), synchronously.
pub fn accept_streams(conn: &Conn, request: &Request) -> Result<Inbound, ErrorObject> {
    let ids: Vec<u32> = match request.method.as_str() {
        method::FILE_PUSH if conn.agent.role == Role::Daemon && conn.agent.has_cap(cap::FILE) => {
            vec![request.decode_params::<FilePushParams>()?.stream]
        }
        method::CLIPBOARD_SET if crate::clipboard::SUPPORTED => {
            let contents: ClipboardContents = request.decode_params()?;
            contents
                .items
                .iter()
                .filter_map(|item| item.stream)
                .collect()
        }
        _ => return Ok(Inbound::new()),
    };
    let mut inbound = Inbound::new();
    for id in ids {
        match conn.accept_host_stream(id) {
            Ok(rx) => {
                inbound.insert(id, rx);
            }
            Err(err) => {
                for id in inbound.keys() {
                    conn.close_inbound(*id);
                }
                return Err(err);
            }
        }
    }
    Ok(inbound)
}

pub async fn handle(
    conn: &Arc<Conn>,
    request: &Request,
    mut inbound: Inbound,
) -> Result<Reply, ErrorObject> {
    let name = request.method.as_str();
    if conn.agent.role == Role::Session {
        return handle_in_session(conn, request, inbound).await;
    }
    if let Some(needed) = required_cap(name)
        && !conn.agent.has_cap(needed)
    {
        return Err(ErrorObject::new(
            ErrorCode::CapUnsupported,
            format!("{name} needs the {needed} cap"),
        ));
    }
    match name {
        method::AGENT_PING => Reply::ok(&Empty {}),
        method::AGENT_INFO => Reply::ok(&conn.agent.info(conn.proto)),
        method::EXEC_START => exec::start(conn, request.decode_params()?).await,
        method::EXEC_SIGNAL => exec::signal(conn, request.decode_params()?),
        method::FILE_PUSH => {
            let params: FilePushParams = request.decode_params()?;
            let inbound = inbound.remove(&params.stream).ok_or_else(|| {
                ErrorObject::new(ErrorCode::InternalError, "stream not registered")
            })?;
            files::push(conn, params, inbound).await
        }
        method::FILE_PULL => files::pull(conn, request.decode_params()?).await,
        method::FILE_STAT => files::stat(request.decode_params()?).await,
        method::FILE_MKDIR_TEMP => files::mkdir_temp(request.decode_params()?).await,
        method::TIME_SET => timesync::set(request.decode_params()?),
        method::POWER_SHUTDOWN => power::shutdown(request.decode_params()?),
        method::NET_ADDRS => netinfo::addrs(),
        method::PORTS_LISTENING => ports::listening().await,
        method::FS_FREEZE => conn.agent.freeze.freeze(request.decode_params()?).await,
        method::FS_THAW => conn.agent.freeze.thaw().await,
        method::SESSION_REVEAL => {
            let link = conn.agent.session.current().ok_or_else(|| {
                ErrorObject::new(ErrorCode::NoSession, "no user session helper is connected")
            })?;
            let params: PathParams = request.decode_params()?;
            let (value, _) = link
                .call(name, relay_params(&params), |_| Vec::new())
                .await?;
            Ok(Reply {
                result: value,
                then: None,
            })
        }
        method::CLIPBOARD_GET | method::CLIPBOARD_SET => {
            crate::clipboard::relay(conn, request, inbound).await
        }
        method::SCREEN_ELEMENTS => {
            // The controls are the logged-in user's: read by their session helper.
            let link = conn.agent.session.current().ok_or_else(|| {
                ErrorObject::new(ErrorCode::NoSession, "nobody is signed in to the guest")
            })?;
            let params: ScreenElementsParams = request.decode_params()?;
            let (value, _) = link
                .call(name, relay_params(&params), |_| Vec::new())
                .await?;
            Ok(Reply {
                result: value,
                then: None,
            })
        }
        // Answered here, by root: never by the session helper, which the signed-in user controls.
        method::SESSION_STATE => {
            let state = tokio::task::spawn_blocking(crate::os::session_state)
                .await
                .map_err(|_| {
                    ErrorObject::new(ErrorCode::InternalError, "reading the session failed")
                })?;
            Reply::ok(&SessionStateResult { state })
        }
        method::DISPLAY_SET => Err(ErrorObject::new(
            ErrorCode::NoSession,
            "no user session helper is connected",
        )),
        method::HELLO => Err(ErrorObject::new(
            ErrorCode::InvalidRequest,
            "hello is sent by the agent",
        )),
        _ => Err(ErrorObject::new(
            ErrorCode::MethodNotFound,
            format!("unknown method {name}"),
        )),
    }
}

/// What a user-session helper serves the daemon: processes as its user, and revealing files in its desktop.
async fn handle_in_session(
    conn: &Arc<Conn>,
    request: &Request,
    inbound: Inbound,
) -> Result<Reply, ErrorObject> {
    match request.method.as_str() {
        method::CLIPBOARD_GET if crate::clipboard::SUPPORTED => {
            crate::clipboard::get(conn, request.decode_params()?).await
        }
        method::CLIPBOARD_SET if crate::clipboard::SUPPORTED => {
            crate::clipboard::set(conn, request.decode_params()?, inbound).await
        }
        method::SCREEN_ELEMENTS if crate::screen::SUPPORTED => {
            crate::screen::elements(request.decode_params()?).await
        }
        method::AGENT_PING => Reply::ok(&Empty {}),
        method::AGENT_INFO => Reply::ok(&conn.agent.info(conn.proto)),
        method::EXEC_START => exec::start(conn, request.decode_params()?).await,
        method::EXEC_SIGNAL => exec::signal(conn, request.decode_params()?),
        method::SESSION_REVEAL => {
            let params: PathParams = request.decode_params()?;
            crate::os::reveal(std::path::Path::new(&params.path))
                .map_err(|err| io_error("cannot reveal it", &err))?;
            Reply::ok(&Empty {})
        }
        name => Err(ErrorObject::new(
            ErrorCode::MethodNotFound,
            format!("{name} is not served by the session helper"),
        )),
    }
}

/// Maps an I/O error to the protocol's error codes.
pub fn io_error(context: &str, err: &std::io::Error) -> ErrorObject {
    let code = match err.kind() {
        std::io::ErrorKind::NotFound => ErrorCode::NotFound,
        std::io::ErrorKind::PermissionDenied => ErrorCode::PermissionDenied,
        std::io::ErrorKind::AlreadyExists => ErrorCode::Busy,
        _ => ErrorCode::IoError,
    };
    ErrorObject::new(code, format!("{context}: {err}"))
}
