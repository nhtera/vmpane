//! VMPane guest agent: a system daemon (root / LocalSystem) that dials the host and serves its requests.
//!
//! Usage: vmpane-agent [--connect <spec>]... [--token-file <path>] [--once] [--verbose] [--version]
//!   spec: auto (default) | vsock[:cid:port] | serial[:path] | tcp:host:port | unix:path
//!   --once: exit when the first connection ends (tests)
#![deny(unsafe_code)]

mod agent;
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
mod timesync;
mod transport;

use std::path::PathBuf;
use std::process::ExitCode;
use std::sync::Arc;
use std::time::{Duration, Instant};

use vmpane_agent_proto::error::ErrorCode;

use crate::agent::Agent;
use crate::connection::ConnError;
use crate::transport::Endpoint;

/// Reconnect delays: 1 s doubling to 30 s; back to 1 s after a connection that lasted.
const BACKOFF_MIN: Duration = Duration::from_secs(1);
const BACKOFF_MAX: Duration = Duration::from_secs(30);
const STABLE_CONNECTION: Duration = Duration::from_secs(10);
/// After the host refused our protocol versions, ask again only rarely (an update may follow).
const REFUSED_DELAY: Duration = Duration::from_secs(300);

struct Args {
    specs: Vec<String>,
    token_file: PathBuf,
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

fn parse_args() -> Result<Option<Args>, String> {
    let mut args = Args {
        specs: Vec::new(),
        token_file: default_token_file(),
        once: false,
        verbose: false,
    };
    let mut it = std::env::args().skip(1);
    while let Some(flag) = it.next() {
        match flag.as_str() {
            "--connect" => args.specs.push(it.next().ok_or("--connect needs a spec")?),
            "--token-file" => {
                args.token_file = it.next().ok_or("--token-file needs a path")?.into()
            }
            "--once" => args.once = true,
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
    log::init(args.verbose);
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
    runtime.block_on(async {
        let agent = Arc::new(Agent::new());
        tokio::select! {
            code = serve(Arc::clone(&agent), args) => code,
            () = stop_signal() => {
                agent.freeze.thaw_on_disconnect().await;
                tracing::info!("stopping");
                ExitCode::SUCCESS
            }
        }
    })
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
    let endpoints: Vec<Endpoint> =
        if args.specs.is_empty() || args.specs.iter().any(|s| s == "auto") {
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
