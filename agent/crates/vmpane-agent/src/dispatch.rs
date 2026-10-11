//! Routes host requests to their handlers, after the cap check.

use std::sync::Arc;

use tokio::sync::mpsc;
use vmpane_agent_proto::error::ErrorCode;
use vmpane_agent_proto::jsonrpc::{ErrorObject, Request};
use vmpane_agent_proto::methods::{Empty, FilePushParams, cap, method};

use crate::connection::{Conn, Incoming, Reply};
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
        _ => return None,
    })
}

/// Registers the host streams a request names, synchronously, before the reader reads their chunks.
pub fn accept_streams(
    conn: &Conn,
    request: &Request,
) -> Result<Option<mpsc::Receiver<Incoming>>, ErrorObject> {
    if request.method != method::FILE_PUSH || !conn.agent.has_cap(cap::FILE) {
        return Ok(None);
    }
    let params: FilePushParams = request.decode_params()?;
    conn.accept_host_stream(params.stream).map(Some)
}

pub async fn handle(
    conn: &Arc<Conn>,
    request: &Request,
    inbound: Option<mpsc::Receiver<Incoming>>,
) -> Result<Reply, ErrorObject> {
    let name = request.method.as_str();
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
            let inbound = inbound.ok_or_else(|| {
                ErrorObject::new(ErrorCode::InternalError, "stream not registered")
            })?;
            files::push(conn, request.decode_params()?, inbound).await
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
        method::SESSION_REVEAL
        | method::CLIPBOARD_GET
        | method::CLIPBOARD_SET
        | method::DISPLAY_SET => Err(ErrorObject::new(
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
