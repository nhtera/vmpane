//! Linux guests.

use std::collections::HashMap;
use std::os::fd::AsRawFd;
use std::time::SystemTime;

use nix::sys::time::TimeSpec;
use nix::time::{ClockId, clock_settime};
use vmpane_agent_proto::error::ErrorCode;
use vmpane_agent_proto::jsonrpc::ErrorObject;
use vmpane_agent_proto::methods::{ExecStartParams, ListeningPort, PortProto, SessionState};

pub const HAS_NET_INFO: bool = true;

pub fn os_version() -> String {
    let release = std::fs::read_to_string("/etc/os-release").unwrap_or_default();
    release
        .lines()
        .find_map(|line| line.strip_prefix("PRETTY_NAME="))
        .map(|name| name.trim_matches('"').to_owned())
        .or_else(|| {
            nix::sys::utsname::uname()
                .ok()
                .map(|u| u.release().to_string_lossy().into_owned())
        })
        .unwrap_or_default()
}

/// IPv4 default gateway from `/proc/net/route`.
pub fn default_gateway() -> Option<String> {
    let routes = std::fs::read_to_string("/proc/net/route").ok()?;
    routes.lines().skip(1).find_map(|line| {
        let fields: Vec<&str> = line.split_whitespace().collect();
        if fields.get(1) != Some(&"00000000") {
            return None;
        }
        let gateway = u32::from_str_radix(fields.get(2)?, 16).ok()?;
        Some(std::net::Ipv4Addr::from(gateway.to_le_bytes()).to_string())
    })
}

pub fn set_clock(when: SystemTime) -> std::io::Result<()> {
    let since = when
        .duration_since(SystemTime::UNIX_EPOCH)
        .map_err(std::io::Error::other)?;
    clock_settime(ClockId::CLOCK_REALTIME, TimeSpec::from(since)).map_err(std::io::Error::from)
}

pub fn shutdown_command(reboot: bool, force: bool) -> (&'static str, Vec<&'static str>) {
    let action = if reboot { "reboot" } else { "poweroff" };
    let mut args = vec![action];
    if force {
        args.push("--force");
    }
    ("systemctl", args)
}

/// Whether `uid` owns an active login session (logind's `/run/systemd/sessions/*`): a seat's foreground
/// session, or, on a guest without seats (servers), any active one. Without logind, any non-root user.
pub fn is_console_user(uid: u32) -> bool {
    match logind_sessions() {
        Some(sessions) => {
            let texts: Vec<String> = sessions.into_iter().map(|(_, text)| text).collect();
            session_allows(&texts, uid)
        }
        None => uid != 0,
    }
}

/// logind's session files (`/run/systemd/sessions/*`) by session id, None without logind.
fn logind_sessions() -> Option<Vec<(String, String)>> {
    let entries = std::fs::read_dir("/run/systemd/sessions").ok()?;
    // Session state files only: logind keeps a `<id>.ref` FIFO beside each, and reading one blocks forever.
    Some(
        entries
            .flatten()
            .filter(|e| {
                e.file_type().is_ok_and(|t| t.is_file())
                    && !e.file_name().to_string_lossy().contains('.')
            })
            .filter_map(|e| {
                let text = std::fs::read_to_string(e.path()).ok()?;
                Some((e.file_name().to_string_lossy().into_owned(), text))
            })
            .collect(),
    )
}

fn field(text: &str, key: &str) -> Option<String> {
    text.lines()
        .find_map(|l| l.strip_prefix(key).map(str::to_owned))
}

/// The seat's foreground session as logind (root) keeps it: the display manager's login screen is a session of
/// class `greeter`. A user session's lock screen is the user's own (its lock hint is the user's to set), so a
/// locked one is never reported as locked: unknown with the hint, unlocked without.
pub fn session_state() -> SessionState {
    logind_sessions().map_or(SessionState::Unknown, |sessions| {
        state_of(&sessions, locked_hint)
    })
}

/// logind's `LockedHint` of session `id` (not in the session files).
fn locked_hint(id: &str) -> bool {
    std::process::Command::new("loginctl")
        .args(["show-session", id, "--property=LockedHint", "--value"])
        .output()
        .is_ok_and(|out| String::from_utf8_lossy(&out.stdout).trim() == "yes")
}

fn state_of(sessions: &[(String, String)], locked: impl Fn(&str) -> bool) -> SessionState {
    let foreground = sessions.iter().find(|(_, s)| {
        field(s, "ACTIVE=").as_deref() == Some("1")
            && field(s, "SEAT=").is_some_and(|seat| !seat.is_empty())
    });
    let Some((id, session)) = foreground else {
        return SessionState::Unknown;
    };
    match field(session, "CLASS=").as_deref() {
        Some("greeter") => SessionState::Greeter,
        Some("user") if locked(id) => SessionState::Unknown,
        Some("user") => SessionState::Unlocked,
        _ => SessionState::Unknown,
    }
}

fn session_allows(sessions: &[String], uid: u32) -> bool {
    let owned = |text: &str| field(text, "UID=").and_then(|u| u.parse::<u32>().ok()) == Some(uid);
    let foreground: Vec<&String> = sessions
        .iter()
        .filter(|s| field(s, "ACTIVE=").as_deref() == Some("1"))
        .collect();
    if !foreground.is_empty() {
        return foreground.iter().any(|s| owned(s));
    }
    sessions
        .iter()
        .any(|s| owned(s) && field(s, "STATE=").as_deref() == Some("active"))
}

pub fn desktop_params(
    params: ExecStartParams,
) -> Result<(ExecStartParams, Option<super::AppLaunch>), ErrorObject> {
    Ok((params, None))
}

/// Processes running `executable` (macOS only: Linux launches are their own process group).
pub fn pids_running(_executable: &std::path::Path) -> Vec<i32> {
    Vec::new()
}

/// The desktop's environment (display, session bus), as the user's systemd manager has it now: the session
/// helper started before the desktop did, so its own environment has none of it. Variables the request sets win.
pub async fn desktop_environment(
    cmd: &mut tokio::process::Command,
    params: &ExecStartParams,
) -> Result<(), ErrorObject> {
    let query = tokio::process::Command::new("systemctl")
        .args(["--user", "show-environment"])
        .kill_on_drop(true)
        .output();
    let out = tokio::time::timeout(std::time::Duration::from_secs(5), query)
        .await
        .map_err(|_| {
            ErrorObject::new(
                ErrorCode::Timeout,
                "the user's systemd manager did not answer",
            )
        })?
        .map_err(|err| crate::dispatch::io_error("cannot read the desktop's environment", &err))?;
    let environment = parse_environment(&String::from_utf8_lossy(&out.stdout));
    if !environment
        .iter()
        .any(|(key, _)| key == "WAYLAND_DISPLAY" || key == "DISPLAY")
    {
        return Err(ErrorObject::new(
            ErrorCode::NoSession,
            "no desktop is running in the guest (a server without one, or nobody signed in to it)",
        ));
    }
    for (key, value) in environment {
        if !params.env.contains_key(&key) {
            cmd.env(key, value);
        }
    }
    Ok(())
}

/// `KEY=value` lines (`systemctl show-environment`; values with special characters come `$'…'`-quoted and are
/// left out: the display and bus variables never need it).
fn parse_environment(text: &str) -> Vec<(String, String)> {
    text.lines()
        .filter_map(|line| line.split_once('='))
        .filter(|(key, value)| {
            !key.is_empty()
                && key.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_')
                && !value.starts_with("$'")
        })
        .map(|(key, value)| (key.to_owned(), value.to_owned()))
        .collect()
}

/// Shows `path` in the desktop's file manager (FileManager1 over D-Bus), else opens its folder.
pub fn reveal(path: &std::path::Path) -> std::io::Result<()> {
    let uri = format!("file://{}", path.display());
    let shown = std::process::Command::new("gdbus")
        .args([
            "call",
            "--session",
            "--dest",
            "org.freedesktop.FileManager1",
            "--object-path",
            "/org/freedesktop/FileManager1",
        ])
        .args([
            "--method",
            "org.freedesktop.FileManager1.ShowItems",
            &format!("['{uri}']"),
            "",
        ])
        .status();
    if shown.is_ok_and(|s| s.success()) {
        return Ok(());
    }
    let folder = path.parent().unwrap_or(path);
    let status = std::process::Command::new("xdg-open")
        .arg(folder)
        .status()?;
    if status.success() {
        Ok(())
    } else {
        Err(std::io::Error::other("xdg-open failed"))
    }
}

// MARK: listening ports

/// Parses one `/proc/net/{tcp,udp}{,6}` table: (address, port, inode) of listening TCP / bound UDP sockets.
fn parse_proc_net(text: &str, tcp: bool, v6: bool) -> Vec<(String, u16, u64)> {
    text.lines()
        .skip(1)
        .filter_map(|line| {
            let fields: Vec<&str> = line.split_whitespace().collect();
            let (local, state, inode) = (fields.get(1)?, fields.get(3)?, fields.get(9)?);
            // TCP LISTEN is 0A; UDP sockets bound but not connected show 07 (TCP_CLOSE).
            if *state != if tcp { "0A" } else { "07" } {
                return None;
            }
            let (addr_hex, port_hex) = local.split_once(':')?;
            let port = u16::from_str_radix(port_hex, 16).ok()?;
            let address = if v6 {
                parse_v6(addr_hex)?
            } else {
                parse_v4(addr_hex)?
            };
            Some((address, port, inode.parse().ok()?))
        })
        .collect()
}

fn parse_v4(hex: &str) -> Option<String> {
    let raw = u32::from_str_radix(hex, 16).ok()?;
    Some(std::net::Ipv4Addr::from(raw.to_le_bytes()).to_string())
}

fn parse_v6(hex: &str) -> Option<String> {
    if hex.len() != 32 {
        return None;
    }
    let mut bytes = [0u8; 16];
    // Four host-order (little-endian) 32-bit words.
    for word in 0..4 {
        let value = u32::from_str_radix(&hex[word * 8..word * 8 + 8], 16).ok()?;
        bytes[word * 4..word * 4 + 4].copy_from_slice(&value.to_le_bytes());
    }
    Some(std::net::Ipv6Addr::from(bytes).to_string())
}

/// socket inode → process name, from `/proc/<pid>/fd`.
fn socket_owners() -> HashMap<u64, String> {
    let mut owners = HashMap::new();
    let Ok(procs) = std::fs::read_dir("/proc") else {
        return owners;
    };
    for entry in procs.flatten() {
        let path = entry.path();
        if !entry
            .file_name()
            .to_string_lossy()
            .bytes()
            .all(|b| b.is_ascii_digit())
        {
            continue;
        }
        let Ok(fds) = std::fs::read_dir(path.join("fd")) else {
            continue;
        };
        let name = std::fs::read_to_string(path.join("comm"))
            .unwrap_or_default()
            .trim()
            .to_owned();
        for fd in fds.flatten() {
            let Ok(target) = std::fs::read_link(fd.path()) else {
                continue;
            };
            let target = target.to_string_lossy();
            if let Some(inode) = target
                .strip_prefix("socket:[")
                .and_then(|t| t.strip_suffix(']'))
                && let Ok(inode) = inode.parse()
            {
                owners.entry(inode).or_insert_with(|| name.clone());
            }
        }
    }
    owners
}

pub fn listening_ports() -> std::io::Result<Vec<ListeningPort>> {
    let owners = socket_owners();
    let mut ports = Vec::new();
    for (file, proto, v6) in [
        ("/proc/net/tcp", PortProto::Tcp, false),
        ("/proc/net/tcp6", PortProto::Tcp, true),
        ("/proc/net/udp", PortProto::Udp, false),
        ("/proc/net/udp6", PortProto::Udp, true),
    ] {
        let Ok(text) = std::fs::read_to_string(file) else {
            continue;
        };
        for (address, port, inode) in parse_proc_net(&text, proto == PortProto::Tcp, v6) {
            ports.push(ListeningPort {
                proto,
                address,
                port,
                process: owners.get(&inode).cloned(),
            });
        }
    }
    Ok(ports)
}

// MARK: freeze

nix::ioctl_readwrite!(fifreeze, b'X', 119, libc::c_int);
nix::ioctl_readwrite!(fithaw, b'X', 120, libc::c_int);

/// Mount points worth freezing: block-device file systems mounted read-write, in /proc/self/mounts order.
fn freezable_mounts() -> std::io::Result<Vec<String>> {
    let mounts = std::fs::read_to_string("/proc/self/mounts")?;
    let mut seen = std::collections::HashSet::new();
    Ok(mounts
        .lines()
        .filter_map(|line| {
            let fields: Vec<&str> = line.split_whitespace().collect();
            let (source, target, options) = (fields.first()?, fields.get(1)?, fields.get(3)?);
            let read_only = options.split(',').any(|o| o == "ro");
            (source.starts_with("/dev/") && !read_only).then(|| unescape_mount(target))
        })
        .filter(|target| seen.insert(target.clone()))
        .collect())
}

/// /proc/self/mounts escapes space, tab, newline and backslash as octal.
fn unescape_mount(text: &str) -> String {
    text.replace("\\040", " ")
        .replace("\\011", "\t")
        .replace("\\012", "\n")
        .replace("\\134", "\\")
}

fn ioctl_on(path: &str, thaw: bool) -> std::io::Result<()> {
    let dir = std::fs::File::open(path)?;
    let mut arg: libc::c_int = 0;
    // SAFETY: FIFREEZE/FITHAW take an ignored int argument; the fd is valid for the call.
    let result = unsafe {
        if thaw {
            fithaw(dir.as_raw_fd(), &mut arg)
        } else {
            fifreeze(dir.as_raw_fd(), &mut arg)
        }
    };
    result.map(|_| ()).map_err(std::io::Error::from)
}

/// Freezes in reverse mount order (children before their parents). File systems that cannot be frozen or are
/// already frozen (a second mount of the same one) are skipped; any other failure thaws what was frozen.
pub fn freeze() -> std::io::Result<Vec<String>> {
    let mut frozen = Vec::new();
    for target in freezable_mounts()?.into_iter().rev() {
        match ioctl_on(&target, false) {
            Ok(()) => frozen.push(target),
            Err(err)
                if matches!(
                    err.raw_os_error(),
                    Some(libc::EOPNOTSUPP | libc::EBUSY | libc::EINVAL)
                ) => {}
            Err(err) => {
                thaw(&frozen);
                return Err(std::io::Error::new(err.kind(), format!("{target}: {err}")));
            }
        }
    }
    Ok(frozen)
}

/// Thaws whatever a previous agent left frozen (it crashed or was killed mid-freeze; the freeze lived only in
/// its memory). File systems that are not frozen answer EINVAL and are skipped.
pub fn thaw_stale() -> Vec<String> {
    freezable_mounts()
        .map(|mounts| thaw(&mounts))
        .unwrap_or_default()
}

/// Thaws in the reverse order of freezing; returns what thawed.
pub fn thaw(frozen: &[String]) -> Vec<String> {
    frozen
        .iter()
        .rev()
        .filter(|target| ioctl_on(target, true).is_ok())
        .cloned()
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_proc_net_tables() {
        let tcp = "  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode\n\
                   0: 00000000:0016 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 1234 1\n\
                   1: 0100007F:0277 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 99 1\n\
                   2: 0F02000A:0016 0202000A:C350 01 00000000:00000000 00:00000000 00000000     0        0 5 1\n";
        assert_eq!(
            parse_proc_net(tcp, true, false),
            vec![("0.0.0.0".into(), 22, 1234), ("127.0.0.1".into(), 631, 99)]
        );
        let tcp6 = "  sl  local_address remote_address st\n\
                    0: 00000000000000000000000001000000:0277 00000000000000000000000000000000:0000 0A 0 0 0 0 0 7 1\n";
        assert_eq!(
            parse_proc_net(tcp6, true, true),
            vec![("::1".into(), 631, 7)]
        );
    }

    #[test]
    fn console_user_follows_logind() {
        let seat = "UID=1000\nSTATE=active\nACTIVE=1\n".to_owned();
        let ssh = "UID=1001\nSTATE=active\n".to_owned();
        assert!(session_allows(&[seat.clone(), ssh.clone()], 1000));
        assert!(
            !session_allows(&[seat, ssh.clone()], 1001),
            "a seat's foreground user wins"
        );
        assert!(session_allows(&[ssh], 1001), "no seats: any active session");
        assert!(!session_allows(&[], 1000));
    }

    #[test]
    fn session_state_follows_the_seats_foreground_session() {
        let session = |id: &str, text: &str| (id.to_owned(), text.to_owned());
        let greeter = session("c1", "UID=120\nCLASS=greeter\nSEAT=seat0\nACTIVE=1\n");
        let user = session("2", "UID=1000\nCLASS=user\nSEAT=seat0\nACTIVE=1\n");
        let ssh = session("3", "UID=1000\nCLASS=user\nACTIVE=1\n");
        let unlocked = |_: &str| false;
        assert_eq!(
            state_of(&[greeter, ssh.clone()], unlocked),
            SessionState::Greeter
        );
        assert_eq!(
            state_of(std::slice::from_ref(&user), unlocked),
            SessionState::Unlocked
        );
        assert_eq!(
            state_of(&[user], |id| id == "2"),
            SessionState::Unknown,
            "the user's own lock is not the system's"
        );
        assert_eq!(
            state_of(&[ssh], unlocked),
            SessionState::Unknown,
            "no seat: no screen"
        );
        assert_eq!(state_of(&[], unlocked), SessionState::Unknown);
    }

    #[test]
    fn reads_the_user_managers_environment() {
        let text = "DISPLAY=:0\nWAYLAND_DISPLAY=wayland-0\nXDG_RUNTIME_DIR=/run/user/1000\nODD=$'a\\nb'\nbad key=1\n";
        assert_eq!(
            parse_environment(text),
            vec![
                ("DISPLAY".into(), ":0".into()),
                ("WAYLAND_DISPLAY".into(), "wayland-0".into()),
                ("XDG_RUNTIME_DIR".into(), "/run/user/1000".into()),
            ]
        );
    }

    #[test]
    fn unescapes_mount_points() {
        assert_eq!(unescape_mount("/mnt/my\\040disk"), "/mnt/my disk");
    }
}
