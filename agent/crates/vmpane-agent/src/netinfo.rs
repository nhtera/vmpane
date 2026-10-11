//! `net.addrs`: interface addresses (a hint for the host, which trusts its own DHCP lease).

use vmpane_agent_proto::jsonrpc::ErrorObject;
use vmpane_agent_proto::methods::NetAddrs;

use crate::connection::Reply;
use crate::dispatch::io_error;

pub fn addrs() -> Result<Reply, ErrorObject> {
    let interfaces =
        crate::os::interfaces().map_err(|err| io_error("cannot list interfaces", &err))?;
    Reply::ok(&NetAddrs { interfaces })
}
