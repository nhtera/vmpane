//! `ports.listening`: TCP sockets in LISTEN and bound UDP sockets, for port forwarding suggestions.

use vmpane_agent_proto::jsonrpc::ErrorObject;
use vmpane_agent_proto::methods::PortsListening;

use crate::connection::Reply;
use crate::dispatch::io_error;

/// At most this many entries go back (the response must fit one frame).
const MAX_PORTS: usize = 2048;

pub async fn listening() -> Result<Reply, ErrorObject> {
    let mut ports = tokio::task::spawn_blocking(crate::os::listening_ports)
        .await
        .map_err(|err| io_error("port scan failed", &std::io::Error::other(err)))?
        .map_err(|err| io_error("cannot list ports", &err))?;
    ports.sort_by(|a, b| (a.port, &a.address).cmp(&(b.port, &b.address)));
    ports.dedup();
    ports.truncate(MAX_PORTS);
    Reply::ok(&PortsListening { ports })
}
