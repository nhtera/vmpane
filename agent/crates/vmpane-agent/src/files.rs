//! `file.push` / `file.pull` / `file.stat` / `file.mkdirTemp`.
//!
//! A push writes to a hidden temporary file beside the target, checks the announced size and SHA-256, syncs,
//! then renames it into place, so the target is either the old file or the whole new one.

use std::path::PathBuf;
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::UNIX_EPOCH;

use bytes::Bytes;
use sha2::{Digest, Sha256};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::sync::mpsc;
use vmpane_agent_proto::error::ErrorCode;
use vmpane_agent_proto::frame::StreamStatus;
use vmpane_agent_proto::jsonrpc::ErrorObject;
use vmpane_agent_proto::methods::{
    FileKind, FilePullParams, FilePullResult, FilePushParams, FilePushResult, FileStat,
    MkdirTempParams, PathParams,
};

use crate::connection::{Conn, Incoming, Reply};
use crate::dispatch::io_error;

const READ_SIZE: usize = 256 << 10;

static TEMP_COUNTER: AtomicU64 = AtomicU64::new(0);

fn absolute(path: &str) -> Result<PathBuf, ErrorObject> {
    let path = PathBuf::from(path);
    if !path.is_absolute() {
        return Err(ErrorObject::new(
            ErrorCode::InvalidParams,
            "the path must be absolute",
        ));
    }
    Ok(path)
}

pub fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn unique_suffix() -> String {
    let nanos = std::time::SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.subsec_nanos())
        .unwrap_or(0);
    format!(
        "{}-{}-{nanos:x}",
        std::process::id(),
        TEMP_COUNTER.fetch_add(1, Ordering::Relaxed)
    )
}

pub async fn push(
    conn: &Arc<Conn>,
    params: FilePushParams,
    inbound: mpsc::Receiver<Incoming>,
) -> Result<Reply, ErrorObject> {
    let stream = params.stream;
    let result = receive(params, inbound).await;
    // Done with the stream either way; later chunks of a refused push are dropped.
    conn.close_inbound(stream);
    Reply::ok(&result?)
}

async fn receive(
    params: FilePushParams,
    mut inbound: mpsc::Receiver<Incoming>,
) -> Result<FilePushResult, ErrorObject> {
    let target = absolute(&params.path)?;
    let expected = params.sha256.to_ascii_lowercase();
    if expected.len() != 64 || !expected.bytes().all(|b| b.is_ascii_hexdigit()) {
        return Err(ErrorObject::new(
            ErrorCode::InvalidParams,
            "sha256 must be 64 hex digits",
        ));
    }
    let (Some(parent), Some(name)) = (target.parent(), target.file_name()) else {
        return Err(ErrorObject::new(
            ErrorCode::InvalidParams,
            "the path has no file name",
        ));
    };
    if !params.overwrite && tokio::fs::symlink_metadata(&target).await.is_ok() {
        return Err(ErrorObject::new(
            ErrorCode::Busy,
            format!("{} exists", target.display()),
        ));
    }
    let temp = parent.join(format!(
        ".{}.vmpane-{}.part",
        name.to_string_lossy(),
        unique_suffix()
    ));
    let mut file = crate::os::create_private(&temp)
        .await
        .map_err(|err| io_error("cannot create the file", &err))?;
    let outcome = async {
        let mut hasher = Sha256::new();
        let mut size = 0u64;
        loop {
            match inbound.recv().await {
                Some(Incoming::Data(data)) => {
                    size += data.len() as u64;
                    if size > params.size {
                        return Err(ErrorObject::new(
                            ErrorCode::Integrity,
                            "more data than the announced size",
                        ));
                    }
                    hasher.update(&data);
                    file.write_all(&data)
                        .await
                        .map_err(|err| io_error("write failed", &err))?;
                }
                Some(Incoming::End(StreamStatus::Ok)) => break,
                Some(Incoming::End(_)) | None => {
                    return Err(ErrorObject::new(
                        ErrorCode::Integrity,
                        "the host ended the stream early",
                    ));
                }
            }
        }
        let digest = hex(&hasher.finalize());
        if size != params.size || digest != expected {
            return Err(ErrorObject::new(
                ErrorCode::Integrity,
                "size or SHA-256 does not match",
            ));
        }
        file.sync_all()
            .await
            .map_err(|err| io_error("sync failed", &err))?;
        crate::os::set_mode(&temp, params.mode.unwrap_or(0o644))
            .map_err(|err| io_error("chmod failed", &err))?;
        tokio::fs::rename(&temp, &target)
            .await
            .map_err(|err| io_error("rename failed", &err))?;
        Ok(FilePushResult {
            size,
            sha256: digest,
        })
    }
    .await;
    if outcome.is_err() {
        let _ = tokio::fs::remove_file(&temp).await;
    }
    outcome
}

pub async fn pull(conn: &Arc<Conn>, params: FilePullParams) -> Result<Reply, ErrorObject> {
    let path = absolute(&params.path)?;
    let mut file = tokio::fs::File::open(&path)
        .await
        .map_err(|err| io_error("cannot open the file", &err))?;
    let meta = file
        .metadata()
        .await
        .map_err(|err| io_error("stat failed", &err))?;
    if !meta.is_file() {
        return Err(ErrorObject::new(
            ErrorCode::InvalidParams,
            "not a regular file",
        ));
    }
    let size = meta.len();
    if size > params.max_bytes {
        return Err(ErrorObject::new(
            ErrorCode::TooLarge,
            format!("{size} bytes is over maxBytes"),
        ));
    }
    let out = conn.open_outbound()?;
    let result = FilePullResult {
        size,
        stream: out.id,
    };
    Reply::then(&result, async move {
        let mut sent = 0u64;
        let mut buf = vec![0u8; READ_SIZE];
        let status = loop {
            // Never more than announced: the host counts on exactly `size` bytes.
            let want = usize::try_from(size - sent)
                .unwrap_or(usize::MAX)
                .min(READ_SIZE);
            if want == 0 {
                break StreamStatus::Ok;
            }
            match file.read(&mut buf[..want]).await {
                Ok(0) => break StreamStatus::Error,
                Ok(n) => {
                    sent += n as u64;
                    if out.send(Bytes::copy_from_slice(&buf[..n])).await.is_err() {
                        return;
                    }
                }
                Err(_) => break StreamStatus::Error,
            }
        };
        let _ = out.finish(status).await;
    })
}

pub async fn stat(params: PathParams) -> Result<Reply, ErrorObject> {
    let path = absolute(&params.path)?;
    let meta = tokio::fs::symlink_metadata(&path)
        .await
        .map_err(|err| io_error("stat failed", &err))?;
    let kind = if meta.file_type().is_symlink() {
        FileKind::Symlink
    } else if meta.is_dir() {
        FileKind::Dir
    } else if meta.is_file() {
        FileKind::File
    } else {
        FileKind::Other
    };
    let mtime_unix_nanos = meta
        .modified()
        .ok()
        .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
        .and_then(|d| i64::try_from(d.as_nanos()).ok())
        .unwrap_or(0);
    Reply::ok(&FileStat {
        kind,
        size: meta.len(),
        mode: crate::os::mode_of(&meta),
        mtime_unix_nanos,
    })
}

pub async fn mkdir_temp(params: MkdirTempParams) -> Result<Reply, ErrorObject> {
    let prefix: String = params
        .prefix
        .chars()
        .filter(|c| c.is_ascii_alphanumeric() || "-_.".contains(*c))
        .take(32)
        .collect();
    let dir = std::env::temp_dir().join(format!(
        "{}{}",
        if prefix.is_empty() {
            "vmpane-"
        } else {
            &prefix
        },
        unique_suffix()
    ));
    crate::os::create_private_dir(&dir)
        .map_err(|err| io_error("cannot create the directory", &err))?;
    Reply::ok(&PathParams {
        path: dir.to_string_lossy().into_owned(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn relative_paths_are_refused() {
        assert!(absolute("tmp/x").is_err());
        assert!(absolute("/tmp/x").is_ok());
    }

    #[tokio::test]
    async fn mkdir_temp_makes_a_private_dir_under_temp() {
        let reply = mkdir_temp(MkdirTempParams {
            prefix: "drop/../x".into(),
        })
        .await
        .unwrap();
        let path = PathBuf::from(reply.result["path"].as_str().unwrap());
        assert!(path.starts_with(std::env::temp_dir()));
        assert!(
            path.file_name()
                .unwrap()
                .to_string_lossy()
                .starts_with("drop..x")
        );
        assert!(path.is_dir());
        std::fs::remove_dir(&path).unwrap();
    }
}
