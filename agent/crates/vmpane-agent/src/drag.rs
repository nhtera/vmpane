//! `drag.probe` (Windows guests): the files a drag in the guest carries while the person drags out of the VM's
//! window on the Mac, so the host can go on with that drag in Finder. The session helper catches the drag
//! (`os::drag_probe`); the daemon relays the request to it, as it does `screen.elements`.

use vmpane_agent_proto::error::ErrorCode;
use vmpane_agent_proto::jsonrpc::ErrorObject;

use crate::connection::Reply;

/// Whether this build can probe a drag ([`vmpane_agent_proto::methods::cap::DRAG`]).
pub const SUPPORTED: bool = cfg!(windows);

/// How long the guest's drag has to reach the probe's window once the pointer is nudged.
#[cfg(windows)]
const ENTER_WAIT: std::time::Duration = std::time::Duration::from_millis(400);
/// How long that window then stays for the drag to end on it (the host lets the guest's button go at once).
#[cfg(windows)]
const LINGER: std::time::Duration = std::time::Duration::from_secs(5);

/// Session helper: what the guest's drag carries (empty without a drag of files).
pub async fn probe() -> Result<Reply, ErrorObject> {
    #[cfg(windows)]
    {
        // The probe's window lingers on its own thread for the drag to end on it.
        let (paths, _window) =
            tokio::task::spawn_blocking(|| crate::os::drag_probe(ENTER_WAIT, LINGER))
                .await
                .map_err(|_| ErrorObject::new(ErrorCode::InternalError, "the drag probe stopped"))?
                .map_err(|err| {
                    ErrorObject::new(
                        ErrorCode::InternalError,
                        format!("cannot probe the drag: {err}"),
                    )
                })?;
        Reply::ok(&result(paths))
    }
    #[cfg(not(windows))]
    {
        Err(ErrorObject::new(
            ErrorCode::CapUnsupported,
            "this guest's agent cannot take drags out of the guest",
        ))
    }
}

#[cfg(windows)]
fn result(paths: Vec<String>) -> vmpane_agent_proto::methods::DragProbeResult {
    use vmpane_agent_proto::methods::{DragItem, DragProbeResult};
    let items = paths
        .into_iter()
        .map(|path| DragItem {
            folder: std::path::Path::new(&path).is_dir(),
            path,
        })
        .collect();
    DragProbeResult { items }
}

/// `vmpane-agent drag-probe` (integration tests, in the signed-in user's desktop): probes a drag as the session
/// helper does, prints the answer as one JSON line at once, and exits once the drag has ended on the probe's
/// window (else, released over another window, it could still drop there).
#[cfg(windows)]
pub fn print_probe() -> std::process::ExitCode {
    use std::io::Write;
    match crate::os::drag_probe(ENTER_WAIT, LINGER) {
        Ok((paths, window)) => {
            println!(
                "{}",
                serde_json::to_string(&result(paths)).unwrap_or_default()
            );
            let _ = std::io::stdout().flush();
            let _ = window.join();
            std::process::ExitCode::SUCCESS
        }
        Err(err) => {
            eprintln!("vmpane-agent: cannot probe the drag: {err}");
            std::process::ExitCode::FAILURE
        }
    }
}
