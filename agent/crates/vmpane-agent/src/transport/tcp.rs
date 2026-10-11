//! TCP fallback: VZ NAT gateway (macOS guests without vsock) or QEMU's `guestfwd` address. The host never
//! exposes it on its own network, and `hello` must carry the per-VM token.

use std::time::Duration;

use super::BoxIo;

pub async fn connect(addr: &str) -> std::io::Result<BoxIo> {
    let stream = tokio::time::timeout(Duration::from_secs(3), tokio::net::TcpStream::connect(addr))
        .await
        .map_err(|_| std::io::Error::from(std::io::ErrorKind::TimedOut))??;
    stream.set_nodelay(true)?;
    Ok(Box::new(stream))
}
