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
    // Any connected stream socket works as a UnixStream: tokio's for reads, a duplicate for writes.
    let std_stream = std::os::unix::net::UnixStream::from(fd);
    std_stream.set_nonblocking(true)?;
    let writer = std_stream.try_clone()?;
    Ok(Box::new(macos::VsockStream::new(
        tokio::net::UnixStream::from_std(std_stream)?,
        writer,
    )))
}

#[cfg(target_os = "macos")]
pub use macos::host_acked;

#[cfg(target_os = "macos")]
mod macos {
    use std::future::Future;
    use std::io::{self, Write};
    use std::os::unix::net::UnixStream;
    use std::pin::Pin;
    use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
    use std::task::{Context, Poll, ready};
    use std::time::Duration;

    use tokio::io::{AsyncRead, AsyncWrite, ReadBuf};
    use tokio::time::Sleep;

    /// Unacknowledged bytes allowed in flight once the host acknowledges (the stall began near 240 KiB).
    const WINDOW: u64 = 128 << 10;
    /// At most this many bytes per write(2).
    const MAX_WRITE: usize = 32 << 10;
    /// How soon a write that had to wait is tried again.
    const RETRY: Duration = Duration::from_millis(1);

    /// Bytes the host has acknowledged on the current connection, and whether it acknowledges at all (an older
    /// host does not: then nothing waits). The daemon has one host connection at a time.
    static ACKED: AtomicU64 = AtomicU64::new(0);
    static ACKING: AtomicBool = AtomicBool::new(false);

    pub fn host_acked(bytes: u64) {
        ACKED.fetch_max(bytes, Ordering::Relaxed);
        ACKING.store(true, Ordering::Relaxed);
    }

    /// A macOS guest's vsock to the host. Its sending side stalls for good once about 240 KiB are in flight (the
    /// host idle in read, the guest's queue never draining; seen with a 256 KiB file chunk, and a stream of
    /// chunks lost data so the host saw broken frames). Linux guests' vsock does not. So writes keep at most
    /// [`WINDOW`] bytes beyond what the host acknowledged (`transport.ack`), retrying on a short timer; reads go
    /// through tokio.
    pub struct VsockStream {
        io: tokio::net::UnixStream,
        /// The same socket (a duplicate descriptor, non-blocking), written to directly.
        writer: UnixStream,
        sent: u64,
        retry: Option<Pin<Box<Sleep>>>,
    }

    impl VsockStream {
        /// A new connection: nothing sent or acknowledged yet.
        pub fn new(io: tokio::net::UnixStream, writer: UnixStream) -> Self {
            ACKED.store(0, Ordering::Relaxed);
            ACKING.store(false, Ordering::Relaxed);
            Self {
                io,
                writer,
                sent: 0,
                retry: None,
            }
        }

        /// How many of `wanted` bytes may go out now.
        fn allowance(&self, wanted: usize) -> usize {
            let mut allowed = wanted.min(MAX_WRITE);
            if ACKING.load(Ordering::Relaxed) {
                let in_flight = self.sent.saturating_sub(ACKED.load(Ordering::Relaxed));
                allowed =
                    allowed.min(usize::try_from(WINDOW.saturating_sub(in_flight)).unwrap_or(0));
            }
            allowed
        }
    }

    impl AsyncRead for VsockStream {
        fn poll_read(
            mut self: Pin<&mut Self>,
            cx: &mut Context<'_>,
            buf: &mut ReadBuf<'_>,
        ) -> Poll<io::Result<()>> {
            Pin::new(&mut self.io).poll_read(cx, buf)
        }
    }

    impl AsyncWrite for VsockStream {
        fn poll_write(
            mut self: Pin<&mut Self>,
            cx: &mut Context<'_>,
            buf: &[u8],
        ) -> Poll<io::Result<usize>> {
            loop {
                if let Some(retry) = self.retry.as_mut() {
                    ready!(retry.as_mut().poll(cx));
                    self.retry = None;
                }
                let allowed = self.allowance(buf.len());
                if allowed == 0 {
                    self.retry = Some(Box::pin(tokio::time::sleep(RETRY)));
                    continue;
                }
                match self.writer.write(&buf[..allowed]) {
                    Ok(written) => {
                        self.sent += written as u64;
                        return Poll::Ready(Ok(written));
                    }
                    Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                        self.retry = Some(Box::pin(tokio::time::sleep(RETRY)));
                    }
                    Err(error) if error.kind() == io::ErrorKind::Interrupted => {}
                    Err(error) => return Poll::Ready(Err(error)),
                }
            }
        }

        fn poll_flush(self: Pin<&mut Self>, _: &mut Context<'_>) -> Poll<io::Result<()>> {
            Poll::Ready(Ok(()))
        }

        fn poll_shutdown(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
            Pin::new(&mut self.io).poll_shutdown(cx)
        }
    }

    #[cfg(test)]
    mod tests {
        use std::sync::atomic::Ordering;
        use std::time::Duration;

        use tokio::io::{AsyncReadExt, AsyncWriteExt};

        use super::{ACKED, VsockStream, WINDOW, host_acked};

        fn pair() -> (VsockStream, tokio::net::UnixStream) {
            let (a, b) = std::os::unix::net::UnixStream::pair().unwrap();
            a.set_nonblocking(true).unwrap();
            b.set_nonblocking(true).unwrap();
            let duplicate = a.try_clone().unwrap();
            (
                VsockStream::new(tokio::net::UnixStream::from_std(a).unwrap(), duplicate),
                tokio::net::UnixStream::from_std(b).unwrap(),
            )
        }

        /// The window: once the host acknowledges, no more than `WINDOW` bytes go out beyond its last
        /// acknowledgement; each acknowledgement lets more through, and every byte arrives in order. A host that
        /// never acknowledges (an older one) is not waited for. One test: the counters are process-wide.
        #[tokio::test]
        async fn writes_keep_within_the_acknowledged_window() {
            // No acknowledgements: 1 MiB goes straight through (a slow reader makes writes block and retry).
            let (mut writer, mut reader) = pair();
            let data: Vec<u8> = (0..(1 << 20)).map(|i| (i % 251) as u8).collect();
            let expected = data.clone();
            let send = tokio::spawn(async move { writer.write_all(&data).await.map(|()| writer) });
            let mut got = vec![0; expected.len()];
            reader.read_exact(&mut got).await.unwrap();
            assert!(got == expected);
            drop(send.await.unwrap().unwrap());

            // Acknowledging host: the writer stops at the window until the next acknowledgement.
            let (mut writer, mut reader) = pair();
            host_acked(0);
            let send =
                tokio::spawn(async move { writer.write_all(&expected).await.map(|()| writer) });
            let mut received = Vec::new();
            let mut piece = vec![0; 64 << 10];
            while received.len() < (1 << 20) {
                let n =
                    tokio::time::timeout(Duration::from_millis(200), reader.read(&mut piece)).await;
                match n {
                    Ok(n) => received.extend_from_slice(&piece[..n.unwrap()]),
                    Err(_) => {
                        // Stalled: exactly at the window past the last acknowledgement.
                        assert_eq!(
                            received.len() as u64,
                            ACKED.load(Ordering::Relaxed) + WINDOW
                        );
                        host_acked(received.len() as u64);
                    }
                }
            }
            send.await.unwrap().unwrap();
            assert!(received == (0..(1 << 20)).map(|i| (i % 251) as u8).collect::<Vec<u8>>());
        }
    }
}
