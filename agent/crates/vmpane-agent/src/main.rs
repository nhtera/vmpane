//! VMPane guest agent: a system daemon (root / LocalSystem) that dials the host and serves its requests, and,
//! as `vmpane-agent session`, the helper in each user session that runs what must run as that user.
//!
//! Usage: vmpane-agent [--connect <spec>]... [--token-file <path>] [--session-socket <path>] [--once]
//!                     [--verbose] [--version]
//!        vmpane-agent session [--socket <path>] [--once] [--verbose]
//!   spec: auto (default) | vsock[:cid:port] | serial[:path] | tcp:host:port | unix:path
//!   --once: exit when the first connection ends (tests)
//!   --session-uid <uid>: accept session helpers of this uid instead of the console user's (tests)
//!   --service: run as the Windows service (the MSI installs it so), logging to %ProgramData%\VMPane
#![deny(unsafe_code)]

mod agent;
mod clipboard;
#[cfg(any(windows, test))]
mod clipformat;
mod connection;
mod dispatch;
mod exec;
mod files;
mod freeze;
mod log;
mod netinfo;
mod os;
mod ports;
mod power;
mod screen;
mod session_link;
mod timesync;
mod transport;

use std::future::Future;
use std::path::PathBuf;
use std::pin::Pin;
use std::process::ExitCode;
use std::sync::Arc;
use std::time::{Duration, Instant};

use vmpane_agent_proto::error::ErrorCode;

use crate::agent::{Agent, Role};
use crate::connection::ConnError;
use crate::transport::Endpoint;

/// Reconnect delays: 1 s doubling to 10 s (a virtio-serial port fails fast until the host attaches, and the agent
/// should connect within 10 s of it); back to 1 s after a connection that lasted.
const BACKOFF_MIN: Duration = Duration::from_secs(1);
const BACKOFF_MAX: Duration = Duration::from_secs(10);
const STABLE_CONNECTION: Duration = Duration::from_secs(10);
/// After the host refused our protocol versions, ask again only rarely (an update may follow).
const REFUSED_DELAY: Duration = Duration::from_secs(300);

struct Args {
    role: Role,
    /// Run under the Windows service control manager.
    #[cfg_attr(not(windows), allow(dead_code))]
    service: bool,
    specs: Vec<String>,
    token_file: PathBuf,
    session_socket: PathBuf,
    session_uid: Option<u32>,
    once: bool,
    verbose: bool,
}

fn default_token_file() -> PathBuf {
    PathBuf::from(if cfg!(target_os = "macos") {
        "/Volumes/My Shared Files/vmpane-tools/token"
    } else if cfg!(windows) {
        r"C:\ProgramData\VMPane\token"
    } else {
        "/mnt/vmpane-tools/token"
    })
}

fn default_session_socket() -> PathBuf {
    #[cfg(unix)]
    {
        os::session_socket()
    }
    #[cfg(not(unix))]
    {
        PathBuf::from(r"\\.\pipe\vmpane-agent")
    }
}

fn parse_args() -> Result<Option<Args>, String> {
    let mut args = Args {
        role: Role::Daemon,
        service: false,
        specs: Vec::new(),
        token_file: default_token_file(),
        session_socket: default_session_socket(),
        session_uid: None,
        once: false,
        verbose: false,
    };
    let mut it = std::env::args().skip(1).peekable();
    if it.peek().map(String::as_str) == Some("session") {
        it.next();
        args.role = Role::Session;
    }
    while let Some(flag) = it.next() {
        match flag.as_str() {
            "--session-socket" | "--socket" => {
                args.session_socket = it.next().ok_or("--socket needs a path")?.into()
            }
            "--session-uid" => {
                let uid = it.next().ok_or("--session-uid needs a uid")?;
                args.session_uid = Some(uid.parse().map_err(|_| "--session-uid needs a number")?);
            }
            "--connect" => args.specs.push(it.next().ok_or("--connect needs a spec")?),
            "--token-file" => {
                args.token_file = it.next().ok_or("--token-file needs a path")?.into()
            }
            "--once" => args.once = true,
            "--service" => args.service = true,
            "--verbose" => args.verbose = true,
            "--version" => {
                println!(
                    "vmpane-agent {} (proto {})",
                    env!("CARGO_PKG_VERSION"),
                    vmpane_agent_proto::PROTO
                );
                return Ok(None);
            }
            other => return Err(format!("unknown argument {other}")),
        }
    }
    Ok(Some(args))
}

fn main() -> ExitCode {
    let args = match parse_args() {
        Ok(Some(args)) => args,
        Ok(None) => return ExitCode::SUCCESS,
        Err(err) => {
            eprintln!("vmpane-agent: {err}");
            return ExitCode::from(2);
        }
    };
    #[cfg(windows)]
    if args.service {
        // Started by the service control manager: stop and session changes come from its handler.
        log::init(args.verbose, Some(log::service_log_path()));
        let started = os::service::run(move |signals| {
            let os::service::Signals { stop, sessions } = signals;
            let stop = Box::pin(async move {
                let _ = stop.await;
            });
            run(args, stop, Some(sessions));
        });
        return if started {
            ExitCode::SUCCESS
        } else {
            ExitCode::FAILURE
        };
    }
    log::init(args.verbose, None);
    run(args, Box::pin(stop_signal()), None)
}

/// Session changes, which restart the user-session helper (Windows service only).
type SessionChanges = Option<tokio::sync::mpsc::UnboundedReceiver<()>>;

fn run(
    args: Args,
    stop: Pin<Box<dyn Future<Output = ()> + Send>>,
    sessions: SessionChanges,
) -> ExitCode {
    if args.role == Role::Daemon {
        let stale = os::thaw_stale();
        if !stale.is_empty() {
            tracing::warn!(?stale, "thawed file systems a previous agent left frozen");
        }
    }
    let runtime = match tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
    {
        Ok(runtime) => runtime,
        Err(err) => {
            tracing::error!(%err, "cannot start the runtime");
            return ExitCode::FAILURE;
        }
    };
    // UI Automation reports a DPI-unaware process's rectangles in scaled points: the session helper asks for the
    // display's pixels. Only there: the same executable is also the LocalSystem service.
    #[cfg(windows)]
    if args.role == Role::Session {
        os::session::use_physical_pixels();
    }
    let code = runtime.block_on(async {
        let agent = Arc::new(Agent::new(args.role));
        #[cfg(unix)]
        if args.role == Role::Daemon {
            let hub = Arc::clone(&agent.session);
            tokio::spawn(hub.listen(args.session_socket.clone(), args.session_uid));
        }
        #[cfg(windows)]
        if let Some(changes) = sessions {
            tokio::spawn(Arc::clone(&agent.session).supervise(changes));
        }
        #[cfg(not(windows))]
        let _ = sessions;
        tokio::select! {
            code = serve(Arc::clone(&agent), args) => code,
            () = stop => {
                agent.freeze.thaw_on_disconnect().await;
                tracing::info!("stopping");
                ExitCode::SUCCESS
            }
        }
    });
    // Blocking work (a process wait, a pending device read) must not hold up a stop.
    runtime.shutdown_timeout(Duration::from_secs(2));
    code
}

async fn stop_signal() {
    #[cfg(unix)]
    {
        use tokio::signal::unix::{SignalKind, signal};
        match signal(SignalKind::terminate()) {
            Ok(mut term) => {
                tokio::select! {
                    _ = term.recv() => {}
                    _ = tokio::signal::ctrl_c() => {}
                }
            }
            Err(_) => {
                let _ = tokio::signal::ctrl_c().await;
            }
        }
    }
    #[cfg(not(unix))]
    {
        let _ = tokio::signal::ctrl_c().await;
    }
}

async fn serve(agent: Arc<Agent>, args: Args) -> ExitCode {
    let endpoints: Vec<Endpoint> = if args.role == Role::Session {
        vec![Endpoint::session(&args.session_socket)]
    } else if args.specs.is_empty() || args.specs.iter().any(|s| s == "auto") {
        Endpoint::auto(&args.token_file)
    } else {
        let mut list = Vec::new();
        for spec in &args.specs {
            match Endpoint::parse(spec, &args.token_file) {
                Some(endpoint) => list.push(endpoint),
                None => {
                    tracing::error!(spec, "bad --connect spec");
                    return ExitCode::from(2);
                }
            }
        }
        list
    };
    tracing::info!(version = env!("CARGO_PKG_VERSION"), endpoints = ?endpoints.iter().map(ToString::to_string).collect::<Vec<_>>(), "starting");
    let mut backoff = BACKOFF_MIN;
    loop {
        let delay = match connect_once(&agent, &endpoints, &args.token_file).await {
            Outcome::NotConnected | Outcome::Ended { stable: false } => {
                let delay = backoff;
                backoff = (backoff * 2).min(BACKOFF_MAX);
                delay
            }
            Outcome::Ended { stable: true } => {
                backoff = BACKOFF_MIN;
                BACKOFF_MIN
            }
            // A helper the daemon refuses is out of date: its service manager starts the installed binary.
            Outcome::Refused if args.role == Role::Session => return ExitCode::SUCCESS,
            Outcome::Refused => REFUSED_DELAY,
        };
        if args.once {
            return ExitCode::SUCCESS;
        }
        tokio::time::sleep(delay).await;
    }
}

enum Outcome {
    NotConnected,
    Ended { stable: bool },
    Refused,
}

/// Tries the endpoints in order and runs the first connection that opens until it ends.
async fn connect_once(
    agent: &Arc<Agent>,
    endpoints: &[Endpoint],
    token_file: &std::path::Path,
) -> Outcome {
    for endpoint in endpoints {
        let token = if endpoint.needs_token() {
            let Some(token) = read_token(token_file) else {
                tracing::debug!(%endpoint, "no token; skipping");
                continue;
            };
            Some(token)
        } else {
            None
        };
        let io = match endpoint.connect().await {
            Ok(io) => io,
            Err(err) => {
                tracing::debug!(%endpoint, %err, "cannot connect");
                continue;
            }
        };
        let started = Instant::now();
        match connection::run(Arc::clone(agent), io, token).await {
            Ok(()) => tracing::info!(%endpoint, "host closed the connection"),
            Err(ConnError::Refused(err))
                if err.known_code() == Some(ErrorCode::ProtoUnsupported) =>
            {
                tracing::error!(%endpoint, message = %err.message, "the host does not speak our protocol; update the guest tools");
                return Outcome::Refused;
            }
            Err(err) => tracing::warn!(%endpoint, %err, "connection ended"),
        }
        return Outcome::Ended {
            stable: started.elapsed() >= STABLE_CONNECTION,
        };
    }
    Outcome::NotConnected
}

/// The per-VM token for TCP (`hello.token`): the first line of the token file.
fn read_token(path: &std::path::Path) -> Option<String> {
    let text = std::fs::read_to_string(path).ok()?;
    let token = text.lines().next()?.trim().to_owned();
    (!token.is_empty()).then_some(token)
}
