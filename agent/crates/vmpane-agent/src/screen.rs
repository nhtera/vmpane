//! `screen.elements`: the controls of the user's foreground window, read by the user-session helper (UI
//! Automation on Windows). The daemon relays the request to the helper, as it does `session.reveal`.

use vmpane_agent_proto::error::ErrorCode;
use vmpane_agent_proto::jsonrpc::ErrorObject;
use vmpane_agent_proto::limits::{SCREEN_MAX_ELEMENTS, SCREEN_MAX_NAME};
use vmpane_agent_proto::methods::{ScreenElements, ScreenElementsParams};

use crate::connection::Reply;

/// Whether this build can list controls ([`vmpane_agent_proto::methods::cap::SCREEN`]).
pub const SUPPORTED: bool = cfg!(windows);

/// Reads them off the runtime thread (a large window takes up to a second), names cut to
/// [`SCREEN_MAX_NAME`] characters.
pub async fn elements(params: ScreenElementsParams) -> Result<Reply, ErrorObject> {
    let max = match params.max_elements {
        0 => SCREEN_MAX_ELEMENTS,
        n => n.min(SCREEN_MAX_ELEMENTS),
    } as usize;
    let mut found = tokio::task::spawn_blocking(move || read(max))
        .await
        .map_err(|_| ErrorObject::new(ErrorCode::InternalError, "the screen reader stopped"))??;
    for element in &mut found.elements {
        element.name = cut(&element.name);
        element.value = element.value.as_deref().map(cut);
    }
    Reply::ok(&found)
}

fn cut(text: &str) -> String {
    text.trim().chars().take(SCREEN_MAX_NAME).collect()
}

#[cfg(windows)]
fn read(max: usize) -> Result<ScreenElements, ErrorObject> {
    crate::os::screen_elements(max)
        .map_err(|err| ErrorObject::new(ErrorCode::InternalError, format!("UI Automation: {err}")))
}

#[cfg(not(windows))]
fn read(_max: usize) -> Result<ScreenElements, ErrorObject> {
    Err(ErrorObject::new(
        ErrorCode::CapUnsupported,
        "this guest cannot list its controls",
    ))
}
