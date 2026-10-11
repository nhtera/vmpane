//! Linux guests.

use std::collections::HashMap;
use std::os::fd::AsRawFd;
use std::time::SystemTime;

use nix::sys::time::TimeSpec;
use nix::time::{ClockId, clock_settime};
use vmpane_agent_proto::methods::{ListeningPort, PortProto};

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
    let Ok(entries) = std::fs::read_dir("/run/systemd/sessions") else {
        return uid != 0;
    };
    let sessions: Vec<String> = entries
        .flatten()
        .filter_map(|e| std::fs::read_to_string(e.path()).ok())
        .collect();
    session_allows(&sessions, uid)
}

fn session_allows(sessions: &[String], uid: u32) -> bool {
    let field = |text: &str, key: &str| {
        text.lines()
            .find_map(|l| l.strip_prefix(key).map(str::to_owned))
    };
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
    fn unescapes_mount_points() {
        assert_eq!(unescape_mount("/mnt/my\\040disk"), "/mnt/my disk");
    }
}
