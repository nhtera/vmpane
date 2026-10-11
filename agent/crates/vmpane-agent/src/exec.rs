//! `exec.start` / `exec.signal`: processes with streamed stdout/stderr (and stdin on request).
//!
//! Each process leads its own process group (Unix) so a timeout, a signal or a disconnect reaches the whole
//! tree; on Windows the tree is killed with `taskkill /T`. A process outliving the connection is killed: its
//! output has nowhere to go.

use std::collections::HashMap;
use std::process::Stdio;
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use bytes::Bytes;
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWriteExt};
use tokio::process::{Child, ChildStdin, Command};
use tokio::sync::{mpsc, watch};
use vmpane_agent_proto::error::ErrorCode;
use vmpane_agent_proto::frame::StreamStatus;
use vmpane_agent_proto::jsonrpc::ErrorObject;
use vmpane_agent_proto::methods::{
    Empty, ExecExited, ExecSignalParams, ExecStartParams, ExecStartResult, RunAs, Signal, method,
};

use crate::agent::Role;
use crate::connection::{Conn, Incoming, OutStream, Reply};
use crate::dispatch::io_error;
use crate::session_link::{SessionLink, StreamNames, relay_params};

/// Output read per chunk.
const READ_SIZE: usize = 64 << 10;
/// After the process exits, how long its output streams may stay open (background children holding them).
const OUTPUT_GRACE: Duration = Duration::from_secs(5);

/// A running exec: a local process (group), or one the user-session helper runs for us.
#[derive(Clone)]
enum Running {
    Local(u32),
    Session {
        link: Arc<SessionLink>,
        exec_id: u32,
    },
}

impl Running {
    fn signal(&self, signal: Signal) {
        match self {
            Running::Local(pid) => crate::os::signal_tree(*pid, signal),
            Running::Session { link, exec_id } => {
                let (link, params) = (
                    Arc::clone(link),
                    ExecSignalParams {
                        exec_id: *exec_id,
                        signal,
                    },
                );
                tokio::spawn(async move {
                    let _ = link
                        .call(method::EXEC_SIGNAL, relay_params(&params), |_| Vec::new())
                        .await;
                });
            }
        }
    }
}

/// Running execs of one connection, by exec id.
#[derive(Default)]
pub struct Registry {
    running: Mutex<HashMap<u32, Running>>,
    next: AtomicU32,
}

impl Registry {
    fn map(&self) -> std::sync::MutexGuard<'_, HashMap<u32, Running>> {
        self.running
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    fn add(&self, running: Running) -> u32 {
        let id = self.next.fetch_add(1, Ordering::Relaxed) + 1;
        self.map().insert(id, running);
        id
    }

    fn remove(&self, id: u32) {
        self.map().remove(&id);
    }

    /// Kills every process still running (the connection ended).
    pub fn kill_all(&self) {
        for (_, running) in self.map().drain() {
            running.signal(Signal::Kill);
        }
    }
}

fn command(params: &ExecStartParams) -> Result<Command, ErrorObject> {
    let mut cmd = match (&params.shell, params.argv.split_first()) {
        (Some(shell), None) => crate::os::shell_command(shell),
        (None, Some((program, args))) => {
            let mut cmd = Command::new(program);
            cmd.args(args);
            cmd
        }
        _ => {
            return Err(ErrorObject::new(
                ErrorCode::InvalidParams,
                "give exactly one of argv and shell",
            ));
        }
    };
    cmd.envs(&params.env)
        .stdin(if params.stdin {
            Stdio::piped()
        } else {
            Stdio::null()
        })
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true);
    if let Some(cwd) = &params.cwd {
        cmd.current_dir(cwd);
    }
    crate::os::own_process_group(&mut cmd);
    Ok(cmd)
}

pub async fn start(conn: &Arc<Conn>, params: ExecStartParams) -> Result<Reply, ErrorObject> {
    // The daemon relays `as: "user"` to the session helper; the helper runs everything as its own user.
    if params.run_as == RunAs::User && conn.agent.role == Role::Daemon {
        return start_in_session(conn, params).await;
    }
    let mut child = command(&params)?
        .spawn()
        .map_err(|err| io_error("cannot start the process", &err))?;
    let pid = child.id().unwrap_or(0);
    let streams = (|| {
        let stdout = conn.open_outbound()?;
        let stderr = conn.open_outbound()?;
        let stdin = if params.stdin {
            Some(conn.open_inbound()?)
        } else {
            None
        };
        Ok::<_, ErrorObject>((stdout, stderr, stdin))
    })();
    let (stdout, stderr, stdin) = match streams {
        Ok(streams) => streams,
        Err(err) => {
            crate::os::signal_tree(pid, Signal::Kill);
            return Err(err);
        }
    };
    let exec_id = conn.execs.add(Running::Local(pid));
    let result = ExecStartResult {
        exec_id,
        stdout: stdout.id,
        stderr: stderr.id,
        stdin: stdin.as_ref().map(|(id, _)| *id),
    };
    let timeout = params.timeout_ms.map(Duration::from_millis);
    let child_stdin = child.stdin.take();
    let conn = Arc::clone(conn);
    Reply::then(&result, async move {
        let exited = run(
            &conn,
            exec_id,
            child,
            stdout,
            stderr,
            stdin.zip(child_stdin),
            timeout,
        )
        .await;
        let notice = ExecExited { exec_id, ..exited };
        let _ = conn.out.notify(method::EXEC_EXITED, &notice).await;
    })
}

async fn run(
    conn: &Arc<Conn>,
    exec_id: u32,
    mut child: Child,
    stdout: OutStream,
    stderr: OutStream,
    stdin: Option<((u32, mpsc::Receiver<Incoming>), ChildStdin)>,
    timeout: Option<Duration>,
) -> ExecExited {
    let pid = child.id().unwrap_or(0);
    let (exited_tx, exited_rx) = watch::channel(false);
    let out_pipe = child.stdout.take();
    let err_pipe = child.stderr.take();

    let wait = async {
        let (status, timed_out) = match timeout {
            Some(limit) => match tokio::time::timeout(limit, child.wait()).await {
                Ok(status) => (status, false),
                Err(_) => {
                    crate::os::signal_tree(pid, Signal::Kill);
                    (child.wait().await, true)
                }
            },
            None => (child.wait().await, false),
        };
        // Reaped: its process group id may be reused, so it can no longer be signalled.
        conn.execs.remove(exec_id);
        let _ = exited_tx.send(true);
        (status, timed_out)
    };
    let output = async {
        let mut grace = exited_rx.clone();
        tokio::select! {
            _ = async { tokio::join!(pump(out_pipe, stdout), pump(err_pipe, stderr)) } => {}
            _ = async {
                let _ = grace.wait_for(|done| *done).await;
                tokio::time::sleep(OUTPUT_GRACE).await;
            } => {}
        }
    };
    let input = async {
        let Some(((id, rx), pipe)) = stdin else {
            return;
        };
        let mut until_exit = exited_rx.clone();
        tokio::select! {
            _ = feed(rx, pipe) => {}
            _ = until_exit.wait_for(|done| *done) => {}
        }
        conn.close_inbound(id);
    };
    let ((status, timed_out), (), ()) = tokio::join!(wait, output, input);
    match status {
        Ok(status) => {
            let (code, signal) = crate::os::exit_parts(&status);
            ExecExited {
                exec_id: 0,
                code,
                signal,
                timed_out,
            }
        }
        Err(err) => {
            tracing::warn!(%err, "waiting for a process failed");
            ExecExited {
                exec_id: 0,
                code: None,
                signal: None,
                timed_out,
            }
        }
    }
}

/// Copies a pipe onto a stream until EOF.
async fn pump(pipe: Option<impl AsyncRead + Unpin>, out: OutStream) {
    let Some(mut pipe) = pipe else {
        let _ = out.finish(StreamStatus::Ok).await;
        return;
    };
    let mut buf = vec![0u8; READ_SIZE];
    loop {
        match pipe.read(&mut buf).await {
            Ok(0) => {
                let _ = out.finish(StreamStatus::Ok).await;
                return;
            }
            Ok(n) => {
                if out.send(Bytes::copy_from_slice(&buf[..n])).await.is_err() {
                    return;
                }
            }
            Err(err) => {
                tracing::debug!(%err, "reading process output failed");
                let _ = out.finish(StreamStatus::Error).await;
                return;
            }
        }
    }
}

/// Copies the host's stdin stream into the process until the stream ends; then closes the pipe.
async fn feed(mut rx: mpsc::Receiver<Incoming>, mut pipe: ChildStdin) {
    while let Some(Incoming::Data(data)) = rx.recv().await {
        if pipe.write_all(&data).await.is_err() {
            return;
        }
    }
    let _ = pipe.shutdown().await;
}

pub fn signal(conn: &Conn, params: ExecSignalParams) -> Result<Reply, ErrorObject> {
    let running = conn.execs.map().get(&params.exec_id).cloned();
    let running = running.ok_or_else(|| {
        ErrorObject::new(
            ErrorCode::NotFound,
            format!("no running exec {}", params.exec_id),
        )
    })?;
    running.signal(params.signal);
    Reply::ok(&Empty {})
}

/// `exec.start {as: "user"}` on the daemon: started by the session helper, whose output and exit are relayed to
/// the host under the daemon's own exec and stream ids.
async fn start_in_session(conn: &Arc<Conn>, params: ExecStartParams) -> Result<Reply, ErrorObject> {
    let link = conn.agent.session.current().ok_or_else(|| {
        ErrorObject::new(ErrorCode::NoSession, "no user session helper is connected")
    })?;
    let names: StreamNames = |v| {
        [&v["stdout"], &v["stderr"]]
            .iter()
            .filter_map(|id| id.as_u64())
            .filter_map(|id| u32::try_from(id).ok())
            .collect()
    };
    let (value, mut helper_streams) = link
        .call(method::EXEC_START, relay_params(&params), names)
        .await?;
    let started: ExecStartResult = serde_json::from_value(value).map_err(|err| {
        ErrorObject::new(
            ErrorCode::InternalError,
            format!("bad helper result: {err}"),
        )
    })?;
    let helper = Running::Session {
        link: Arc::clone(&link),
        exec_id: started.exec_id,
    };
    let streams = (|| {
        let stdout = conn.open_outbound()?;
        let stderr = conn.open_outbound()?;
        let stdin = if params.stdin {
            Some(conn.open_inbound()?)
        } else {
            None
        };
        Ok::<_, ErrorObject>((stdout, stderr, stdin))
    })();
    let (stdout, stderr, stdin) = match streams {
        Ok(streams) => streams,
        Err(err) => {
            helper.signal(Signal::Kill);
            return Err(err);
        }
    };
    let exec_id = conn.execs.add(helper);
    let result = ExecStartResult {
        exec_id,
        stdout: stdout.id,
        stderr: stderr.id,
        stdin: stdin.as_ref().map(|(id, _)| *id),
    };
    let (helper_out, helper_err) = (
        helper_streams.remove(&started.stdout),
        helper_streams.remove(&started.stderr),
    );
    let conn = Arc::clone(conn);
    Reply::then(&result, async move {
        let feed = stdin.zip(started.stdin).map(|((id, rx), helper_stdin)| {
            let (conn, link) = (Arc::clone(&conn), Arc::clone(&link));
            tokio::spawn(async move {
                relay_stdin(rx, &link, helper_stdin).await;
                conn.close_inbound(id);
            })
        });
        let (_, _, exited) = tokio::join!(
            relay_output(helper_out, stdout),
            relay_output(helper_err, stderr),
            link.exited(started.exec_id)
        );
        if let Some(feed) = feed {
            feed.abort();
        }
        conn.execs.remove(exec_id);
        let notice = match exited {
            Some(exited) => ExecExited { exec_id, ..exited },
            None => ExecExited {
                exec_id,
                code: None,
                signal: Some("disconnected".into()),
                timed_out: false,
            },
        };
        let _ = conn.out.notify(method::EXEC_EXITED, &notice).await;
    })
}

/// Copies a helper stream onto a host stream, ending it the way the helper ended its own.
pub(crate) async fn relay_output(helper: Option<mpsc::Receiver<Incoming>>, out: OutStream) {
    let Some(mut helper) = helper else {
        let _ = out.finish(StreamStatus::Error).await;
        return;
    };
    while let Some(item) = helper.recv().await {
        match item {
            Incoming::Data(data) => {
                if out.send(data).await.is_err() {
                    return;
                }
            }
            Incoming::End(status) => {
                let _ = out.finish(status).await;
                return;
            }
        }
    }
    let _ = out.finish(StreamStatus::Error).await; // the helper went away
}

async fn relay_stdin(mut host: mpsc::Receiver<Incoming>, link: &SessionLink, helper_stdin: u32) {
    while let Some(item) = host.recv().await {
        match item {
            Incoming::Data(data) => {
                if !link.send(helper_stdin, data).await {
                    return;
                }
            }
            Incoming::End(status) => {
                link.end(helper_stdin, status).await;
                return;
            }
        }
    }
}
