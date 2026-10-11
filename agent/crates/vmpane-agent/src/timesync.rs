//! `time.set`: the host sets the guest clock after a resume or a snapshot restore.

use std::time::{Duration, UNIX_EPOCH};

use vmpane_agent_proto::error::ErrorCode;
use vmpane_agent_proto::jsonrpc::ErrorObject;
use vmpane_agent_proto::methods::{Empty, TimeSetParams};

use crate::connection::Reply;
use crate::dispatch::io_error;

pub fn set(params: TimeSetParams) -> Result<Reply, ErrorObject> {
    let nanos = u64::try_from(params.unix_nanos)
        .map_err(|_| ErrorObject::new(ErrorCode::InvalidParams, "unixNanos is before 1970"))?;
    let when = UNIX_EPOCH + Duration::from_nanos(nanos);
    crate::os::set_clock(when).map_err(|err| io_error("cannot set the clock", &err))?;
    tracing::info!(unix_nanos = params.unix_nanos, "clock set by the host");
    Reply::ok(&Empty {})
}
