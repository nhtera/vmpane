//! virtio-serial port (QEMU guests). A port opens only once, so on Linux reads and writes go through two
//! handles to the same open file (a dup), each with its own blocking worker: a read waiting for the host never
//! holds up a write. Windows serializes synchronous I/O per file object, so there the port is overlapped
//! (`os::windows::serial`).

use std::path::{Path, PathBuf};
#[cfg(not(windows))]
use std::pin::Pin;
#[cfg(not(windows))]
use std::task::{Context, Poll};

#[cfg(not(windows))]
use tokio::io::{AsyncRead, AsyncWrite, ReadBuf};

use super::BoxIo;

pub fn default_path() -> PathBuf {
    if cfg!(windows) {
        PathBuf::from(format!(
            r"\\.\Global\{}",
            vmpane_agent_proto::SERIAL_PORT_NAME
        ))
    } else {
        PathBuf::from(format!(
            "/dev/virtio-ports/{}",
            vmpane_agent_proto::SERIAL_PORT_NAME
        ))
    }
}

#[cfg(windows)]
pub async fn open(path: &Path) -> std::io::Result<BoxIo> {
    crate::os::serial::open(path).await
}

#[cfg(not(windows))]
pub async fn open(path: &Path) -> std::io::Result<BoxIo> {
    let path = path.to_owned();
    let (reader, writer) = tokio::task::spawn_blocking(move || -> std::io::Result<_> {
        let file = crate::os::open_serial(&path)?;
        let writer = file.try_clone()?;
        Ok((file, writer))
    })
    .await
    .map_err(std::io::Error::other)??;
    Ok(Box::new(SerialPort {
        reader: tokio::fs::File::from_std(reader),
        writer: tokio::fs::File::from_std(writer),
    }))
}

#[cfg(not(windows))]
struct SerialPort {
    reader: tokio::fs::File,
    writer: tokio::fs::File,
}

#[cfg(not(windows))]
impl AsyncRead for SerialPort {
    fn poll_read(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &mut ReadBuf<'_>,
    ) -> Poll<std::io::Result<()>> {
        Pin::new(&mut self.reader).poll_read(cx, buf)
    }
}

#[cfg(not(windows))]
impl AsyncWrite for SerialPort {
    fn poll_write(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &[u8],
    ) -> Poll<std::io::Result<usize>> {
        Pin::new(&mut self.writer).poll_write(cx, buf)
    }

    fn poll_flush(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<std::io::Result<()>> {
        Pin::new(&mut self.writer).poll_flush(cx)
    }

    fn poll_shutdown(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<std::io::Result<()>> {
        Pin::new(&mut self.writer).poll_shutdown(cx)
    }
}
