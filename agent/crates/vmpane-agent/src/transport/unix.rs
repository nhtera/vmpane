//! Unix socket to a host stand-in (tests and development only), and a session helper's to its daemon.

use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};

use super::BoxIo;

/// Whether the last socket connected to is served by root (a session helper: by the system's daemon, not a
/// stand-in some other program started).
static PEER_IS_ROOT: AtomicBool = AtomicBool::new(false);

pub async fn connect(path: &Path) -> std::io::Result<BoxIo> {
    let stream = tokio::net::UnixStream::connect(path).await?;
    let root = stream
        .peer_cred()
        .map(|cred| cred.uid() == 0)
        .unwrap_or(false);
    PEER_IS_ROOT.store(root, Ordering::Release);
    Ok(Box::new(stream))
}

/// See `PEER_IS_ROOT`.
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
pub fn peer_is_root() -> bool {
    PEER_IS_ROOT.load(Ordering::Acquire)
}
