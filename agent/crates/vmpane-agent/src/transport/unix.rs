//! Unix socket to a host stand-in (tests and development only).

use std::path::Path;

use super::BoxIo;

pub async fn connect(path: &Path) -> std::io::Result<BoxIo> {
    Ok(Box::new(tokio::net::UnixStream::connect(path).await?))
}
