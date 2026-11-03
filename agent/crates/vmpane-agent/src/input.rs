//! `input.idle` (Windows guests): how long ago the signed-in user's session last took input. After the host pauses
//! the guest (a live snapshot), Windows can drop the first key it is sent; the host sends a harmless key (right Ctrl
//! alone) and waits until this says the guest has it, so an agent's own input is not the one lost. The session helper reads it
//! (`GetLastInputInfo` answers only for the caller's session); the daemon relays the request, as `drag.probe`.

use vmpane_agent_proto::error::ErrorCode;
use vmpane_agent_proto::jsonrpc::ErrorObject;
#[cfg(windows)]
use vmpane_agent_proto::methods::InputIdleResult;

use crate::connection::Reply;

/// Whether this build can tell ([`vmpane_agent_proto::methods::cap::INPUT_IDLE`]).
pub const SUPPORTED: bool = cfg!(windows);

/// Session helper: milliseconds since the session's last input.
pub fn idle() -> Result<Reply, ErrorObject> {
    #[cfg(windows)]
    {
        let idle_ms = crate::os::input_idle_ms().ok_or_else(|| {
            ErrorObject::new(
                ErrorCode::InternalError,
                "the session's last input cannot be read",
            )
        })?;
        Reply::ok(&InputIdleResult { idle_ms })
    }
    #[cfg(not(windows))]
    {
        Err(ErrorObject::new(
            ErrorCode::CapUnsupported,
            "input.idle is not served on this system",
        ))
    }
}
