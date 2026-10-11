//! The virtio-serial port on Windows. A port opens only once, and synchronous I/O on one file object is
//! serialized (a pending read would hold up every write), so the port is opened for overlapped I/O and served
//! by two threads, one reading and one writing, each with its own OVERLAPPED. They are bridged to the async side
//! through an in-memory duplex stream.

use std::path::Path;
use std::sync::Arc;

use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::sync::mpsc;
use windows::Win32::Foundation::{
    CloseHandle, ERROR_IO_PENDING, GENERIC_READ, GENERIC_WRITE, HANDLE,
};
use windows::Win32::Storage::FileSystem::{
    CreateFileW, FILE_FLAG_OVERLAPPED, FILE_SHARE_NONE, OPEN_EXISTING, ReadFile, WriteFile,
};
use windows::Win32::System::IO::{CancelIoEx, GetOverlappedResult, OVERLAPPED};
use windows::Win32::System::Threading::CreateEventW;
use windows::core::HSTRING;

use crate::transport::BoxIo;

/// The port handle, closed when the last thread lets go of it.
struct Port(HANDLE);

// SAFETY: a file handle may be used from any thread; overlapped calls on it are independent.
unsafe impl Send for Port {}
unsafe impl Sync for Port {}

impl Drop for Port {
    fn drop(&mut self) {
        // SAFETY: the handle came from CreateFileW and is closed exactly once.
        unsafe {
            let _ = CloseHandle(self.0);
        }
    }
}

impl Port {
    /// One overlapped read or write, waited for; returns the bytes transferred.
    fn transfer(&self, read: Option<&mut [u8]>, write: Option<&[u8]>) -> std::io::Result<usize> {
        // SAFETY: the event and OVERLAPPED outlive the call, which completes (or fails) before they are dropped:
        // GetOverlappedResult waits for it.
        unsafe {
            let event = CreateEventW(None, true, false, None).map_err(std::io::Error::other)?;
            let mut overlapped = OVERLAPPED {
                hEvent: event,
                ..Default::default()
            };
            let started = match (read, write) {
                (Some(buf), _) => ReadFile(self.0, Some(buf), None, Some(&mut overlapped)),
                (None, Some(buf)) => WriteFile(self.0, Some(buf), None, Some(&mut overlapped)),
                (None, None) => Ok(()),
            };
            let result = match started {
                Err(err) if err.code() != ERROR_IO_PENDING.to_hresult() => {
                    Err(std::io::Error::other(err))
                }
                _ => {
                    let mut transferred = 0u32;
                    GetOverlappedResult(self.0, &overlapped, &mut transferred, true)
                        .map(|()| transferred as usize)
                        .map_err(std::io::Error::other)
                }
            };
            let _ = CloseHandle(event);
            result
        }
    }

    /// Ends a read that is waiting for the host (the connection went away).
    fn cancel(&self) {
        // SAFETY: cancelling I/O on an open handle; a no-op when nothing is pending.
        unsafe {
            let _ = CancelIoEx(self.0, None);
        }
    }
}

pub async fn open(path: &Path) -> std::io::Result<BoxIo> {
    let name = HSTRING::from(path.as_os_str());
    // SAFETY: CreateFileW with a valid path; the handle goes straight into `Port`.
    let handle = unsafe {
        CreateFileW(
            &name,
            (GENERIC_READ | GENERIC_WRITE).0,
            FILE_SHARE_NONE,
            None,
            OPEN_EXISTING,
            FILE_FLAG_OVERLAPPED,
            None,
        )
    }
    .map_err(std::io::Error::other)?;
    let port = Arc::new(Port(handle));
    let (ours, theirs) = tokio::io::duplex(256 << 10);
    let (mut from_connection, mut to_connection) = tokio::io::split(theirs);

    // Port → connection.
    let (in_tx, mut in_rx) = mpsc::channel::<Vec<u8>>(8);
    let reader = Arc::clone(&port);
    std::thread::Builder::new()
        .name("vmpane-serial-read".into())
        .spawn(move || {
            let mut buf = vec![0u8; 64 << 10];
            loop {
                match reader.transfer(Some(&mut buf), None) {
                    Ok(0) | Err(_) => break,
                    Ok(n) => {
                        if in_tx.blocking_send(buf[..n].to_vec()).is_err() {
                            break;
                        }
                    }
                }
            }
        })?;
    tokio::spawn(async move {
        while let Some(data) = in_rx.recv().await {
            if to_connection.write_all(&data).await.is_err() {
                break;
            }
        }
        let _ = to_connection.shutdown().await;
    });

    // Connection → port.
    let (out_tx, mut out_rx) = mpsc::channel::<Vec<u8>>(8);
    let writer = Arc::clone(&port);
    std::thread::Builder::new()
        .name("vmpane-serial-write".into())
        .spawn(move || {
            while let Some(data) = out_rx.blocking_recv() {
                let mut sent = 0;
                while sent < data.len() {
                    match writer.transfer(None, Some(&data[sent..])) {
                        Ok(0) | Err(_) => return,
                        Ok(n) => sent += n,
                    }
                }
            }
        })?;
    tokio::spawn(async move {
        let mut buf = vec![0u8; 64 << 10];
        loop {
            match from_connection.read(&mut buf).await {
                Ok(0) | Err(_) => break,
                Ok(n) => {
                    if out_tx.send(buf[..n].to_vec()).await.is_err() {
                        break;
                    }
                }
            }
        }
        // The connection is gone: wake the reader so the port closes and can be opened again.
        drop(out_tx);
        port.cancel();
    });
    Ok(Box::new(ours))
}
