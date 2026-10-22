//! Shared by Linux and macOS guests.

use std::collections::BTreeMap;
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt, PermissionsExt};
use std::os::unix::process::ExitStatusExt;
use std::path::Path;
use std::process::ExitStatus;

use nix::ifaddrs::getifaddrs;
use nix::sys::signal::{Signal as NixSignal, killpg};
use nix::unistd::Pid;
use vmpane_agent_proto::methods::{NetInterface, Signal};

/// Signals a process group (the exec's process leads its own group).
pub fn signal_tree(pid: u32, signal: Signal) {
    let Ok(pid) = i32::try_from(pid) else { return };
    if pid <= 1 {
        return;
    }
    let sig = match signal {
        Signal::Int => NixSignal::SIGINT,
        Signal::Term => NixSignal::SIGTERM,
        Signal::Kill => NixSignal::SIGKILL,
    };
    let _ = killpg(Pid::from_raw(pid), sig);
}

/// An app a desktop launch hands to the system (macOS `open`): its executable, and the instances that ran before.
pub struct AppLaunch {
    pub executable: std::path::PathBuf,
    pub before: Vec<i32>,
}

/// A desktop launch: the process group it leads, and the app it had the system open (macOS).
pub struct DesktopTree {
    pgid: u32,
    app: Option<AppLaunch>,
    started: std::time::Instant,
    /// The app has been seen running.
    seen: std::sync::atomic::AtomicBool,
}

/// How long an app handed to the system may take to show up before the launch counts as ended.
const APP_START: std::time::Duration = std::time::Duration::from_secs(10);

impl DesktopTree {
    pub fn adopt(
        _child: &tokio::process::Child,
        pid: u32,
        app: Option<AppLaunch>,
    ) -> std::io::Result<DesktopTree> {
        Ok(DesktopTree {
            pgid: pid,
            app,
            started: std::time::Instant::now(),
            seen: std::sync::atomic::AtomicBool::new(false),
        })
    }

    /// The app's instances started since the launch.
    fn app_pids(&self) -> Vec<i32> {
        self.app.as_ref().map_or_else(Vec::new, |app| {
            crate::os::pids_running(&app.executable)
                .into_iter()
                .filter(|pid| !app.before.contains(pid))
                .collect()
        })
    }

    pub fn signal(&self, signal: Signal) {
        signal_tree(self.pgid, signal);
        let sig = match signal {
            Signal::Int => NixSignal::SIGINT,
            Signal::Term => NixSignal::SIGTERM,
            Signal::Kill => NixSignal::SIGKILL,
        };
        for pid in self.app_pids() {
            let _ = nix::sys::signal::kill(Pid::from_raw(pid), sig);
        }
    }

    /// Whether anything of the launch still runs: its process group, or the app (which may still be starting).
    pub fn alive(&self) -> bool {
        use std::sync::atomic::Ordering;
        let group = i32::try_from(self.pgid)
            .is_ok_and(|pgid| pgid > 1 && killpg(Pid::from_raw(pgid), None).is_ok());
        if group || self.app.is_none() {
            return group;
        }
        if !self.app_pids().is_empty() {
            self.seen.store(true, Ordering::Relaxed);
            return true;
        }
        !self.seen.load(Ordering::Relaxed) && self.started.elapsed() < APP_START
    }
}

pub fn shell_command(shell: &str) -> tokio::process::Command {
    let mut cmd = tokio::process::Command::new("/bin/sh");
    cmd.arg("-c").arg(shell);
    cmd
}

pub fn own_process_group(cmd: &mut tokio::process::Command) {
    cmd.process_group(0);
}

pub fn exit_parts(status: &ExitStatus) -> (Option<i32>, Option<String>) {
    let signal = status
        .signal()
        .map(|n| NixSignal::try_from(n).map_or_else(|_| n.to_string(), |s| s.as_str().to_owned()));
    (status.code(), signal)
}

/// A new file only the agent can read until it is complete.
pub async fn create_private(path: &Path) -> std::io::Result<tokio::fs::File> {
    let mut options = std::fs::OpenOptions::new();
    options.write(true).create_new(true).mode(0o600);
    let path = path.to_owned();
    let file = tokio::task::spawn_blocking(move || options.open(path))
        .await
        .map_err(std::io::Error::other)??;
    Ok(tokio::fs::File::from_std(file))
}

pub fn set_mode(path: &Path, mode: u32) -> std::io::Result<()> {
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(mode & 0o7777))
}

pub fn mode_of(meta: &std::fs::Metadata) -> u32 {
    meta.permissions().mode() & 0o7777
}

pub fn create_private_dir(path: &Path) -> std::io::Result<()> {
    std::fs::DirBuilder::new().mode(0o700).create(path)
}

pub fn open_serial(path: &Path) -> std::io::Result<std::fs::File> {
    std::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .custom_flags(libc::O_NOCTTY)
        .open(path)
}

/// The daemon's socket for user-session helpers.
pub fn session_socket() -> std::path::PathBuf {
    std::path::PathBuf::from(if cfg!(target_os = "macos") {
        "/var/run/vmpane-agent.sock"
    } else {
        "/run/vmpane-agent.sock"
    })
}

/// Interfaces with their MAC and IP addresses (loopback left out).
pub fn interfaces() -> std::io::Result<Vec<NetInterface>> {
    let mut by_name: BTreeMap<String, NetInterface> = BTreeMap::new();
    for ifa in getifaddrs().map_err(std::io::Error::from)? {
        if ifa
            .flags
            .contains(nix::net::if_::InterfaceFlags::IFF_LOOPBACK)
        {
            continue;
        }
        let entry = by_name
            .entry(ifa.interface_name.clone())
            .or_insert_with(|| NetInterface {
                name: ifa.interface_name.clone(),
                ..NetInterface::default()
            });
        let Some(address) = ifa.address else { continue };
        if let Some(v4) = address.as_sockaddr_in() {
            entry.ipv4.push(v4.ip().to_string());
        } else if let Some(v6) = address.as_sockaddr_in6() {
            entry.ipv6.push(v6.ip().to_string());
        } else if let Some(link) = address.as_link_addr()
            && let Some(mac) = link.addr()
            && mac != [0; 6]
        {
            entry.mac = Some(
                mac.iter()
                    .map(|b| format!("{b:02x}"))
                    .collect::<Vec<_>>()
                    .join(":"),
            );
        }
    }
    Ok(by_name.into_values().collect())
}
