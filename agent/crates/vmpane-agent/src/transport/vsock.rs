//! vsock to the host (VZ guests): tokio-vsock on Linux, a raw AF_VSOCK socket on macOS guests.

use std::time::Duration;

use super::BoxIo;

const CONNECT_TIMEOUT: Duration = Duration::from_secs(3);

#[cfg(target_os = "linux")]
pub async fn connect(cid: u32, port: u32) -> std::io::Result<BoxIo> {
    let addr = tokio_vsock::VsockAddr::new(cid, port);
    let stream = tokio::time::timeout(CONNECT_TIMEOUT, tokio_vsock::VsockStream::connect(addr))
        .await
        .map_err(|_| std::io::Error::from(std::io::ErrorKind::TimedOut))??;
    Ok(Box::new(stream))
}

#[cfg(target_os = "macos")]
pub async fn connect(cid: u32, port: u32) -> std::io::Result<BoxIo> {
    let fd = tokio::time::timeout(
        CONNECT_TIMEOUT,
        tokio::task::spawn_blocking(move || crate::os::vsock_connect(cid, port)),
    )
    .await
    .map_err(|_| std::io::Error::from(std::io::ErrorKind::TimedOut))?
    .map_err(std::io::Error::other)??;
    // Any connected stream socket works as a tokio UnixStream for reads and writes.
    let std_stream = std::os::unix::net::UnixStream::from(fd);
    std_stream.set_nonblocking(true)?;
    Ok(Box::new(tokio::net::UnixStream::from_std(std_stream)?))
}
