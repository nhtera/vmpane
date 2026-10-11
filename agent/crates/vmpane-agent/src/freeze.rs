//! `fs.freeze` / `fs.thaw` around disk snapshots. A freeze always ends: by `fs.thaw`, by its timeout, or by
//! the host disconnecting. While frozen, logs stay in memory (writing them could block on a frozen disk).

use std::sync::Arc;
use std::time::Duration;

use tokio::sync::Mutex;
use tokio::task::JoinHandle;
use vmpane_agent_proto::error::ErrorCode;
use vmpane_agent_proto::jsonrpc::ErrorObject;
use vmpane_agent_proto::limits::{FREEZE_DEFAULT_TIMEOUT_MS, FREEZE_MAX_TIMEOUT_MS};
use vmpane_agent_proto::methods::{FsFreezeParams, FsFreezeResult, FsThawResult};

use crate::connection::Reply;
use crate::dispatch::io_error;

struct Frozen {
    targets: Vec<String>,
    timer: JoinHandle<()>,
}

#[derive(Default)]
pub struct Freeze {
    state: Arc<Mutex<Option<Frozen>>>,
}

impl Freeze {
    pub async fn freeze(&self, params: FsFreezeParams) -> Result<Reply, ErrorObject> {
        let timeout_ms = params.timeout_ms.unwrap_or(FREEZE_DEFAULT_TIMEOUT_MS);
        if timeout_ms == 0 || timeout_ms > FREEZE_MAX_TIMEOUT_MS {
            return Err(ErrorObject::new(
                ErrorCode::InvalidParams,
                format!("timeoutMs must be 1..={FREEZE_MAX_TIMEOUT_MS}"),
            ));
        }
        let mut state = self.state.lock().await;
        if state.is_some() {
            return Err(ErrorObject::new(ErrorCode::Busy, "already frozen"));
        }
        crate::log::hold(true);
        let targets = match tokio::task::spawn_blocking(crate::os::freeze).await {
            Ok(Ok(targets)) => targets,
            Ok(Err(err)) => {
                crate::log::hold(false);
                return Err(io_error("freeze failed", &err));
            }
            Err(err) => {
                crate::log::hold(false);
                return Err(io_error("freeze failed", &std::io::Error::other(err)));
            }
        };
        let shared = Arc::clone(&self.state);
        let timer = tokio::spawn(async move {
            tokio::time::sleep(Duration::from_millis(timeout_ms)).await;
            if let Some(frozen) = shared.lock().await.take() {
                let thawed = thaw_targets(frozen.targets).await;
                tracing::warn!(?thawed, "freeze timed out; thawed");
            }
        });
        *state = Some(Frozen {
            targets: targets.clone(),
            timer,
        });
        Reply::ok(&FsFreezeResult { frozen: targets })
    }

    pub async fn thaw(&self) -> Result<Reply, ErrorObject> {
        Reply::ok(&FsThawResult {
            thawed: self.thaw_now().await,
        })
    }

    /// The host went away: never leave the guest frozen.
    pub async fn thaw_on_disconnect(&self) {
        let thawed = self.thaw_now().await;
        if !thawed.is_empty() {
            tracing::warn!(?thawed, "host disconnected while frozen; thawed");
        }
    }

    async fn thaw_now(&self) -> Vec<String> {
        let Some(frozen) = self.state.lock().await.take() else {
            return Vec::new();
        };
        frozen.timer.abort();
        thaw_targets(frozen.targets).await
    }
}

async fn thaw_targets(targets: Vec<String>) -> Vec<String> {
    let thawed = tokio::task::spawn_blocking(move || crate::os::thaw(&targets))
        .await
        .unwrap_or_default();
    crate::log::hold(false);
    thawed
}
