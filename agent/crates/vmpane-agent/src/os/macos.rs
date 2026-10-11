//! macOS guests.

use std::os::fd::{FromRawFd, OwnedFd};
use std::process::Command;
use std::time::SystemTime;

use vmpane_agent_proto::methods::{ListeningPort, PortProto};

pub const HAS_NET_INFO: bool = true;

pub fn os_version() -> String {
    Command::new("/usr/bin/sw_vers")
        .arg("-productVersion")
        .output()
        .ok()
        .map(|out| String::from_utf8_lossy(&out.stdout).trim().to_owned())
        .unwrap_or_default()
}

/// The default IPv4 gateway (the host on VZ NAT), from `route -n get default`.
pub fn default_gateway() -> Option<String> {
    let out = Command::new("/sbin/route")
        .args(["-n", "get", "default"])
        .output()
        .ok()?;
    String::from_utf8_lossy(&out.stdout)
        .lines()
        .find_map(|line| {
            line.trim()
                .strip_prefix("gateway:")
                .map(|g| g.trim().to_owned())
        })
        .filter(|g| g.parse::<std::net::Ipv4Addr>().is_ok())
}

/// A connected AF_VSOCK stream socket (blocking connect; call off the async runtime).
pub fn vsock_connect(cid: u32, port: u32) -> std::io::Result<OwnedFd> {
    // SAFETY: socket(2) returns a new fd or -1; ownership moves into OwnedFd at once.
    let fd = unsafe { libc::socket(libc::AF_VSOCK, libc::SOCK_STREAM, 0) };
    if fd < 0 {
        return Err(std::io::Error::last_os_error());
    }
    // SAFETY: fd is a valid, open socket that nothing else owns.
    let owned = unsafe { OwnedFd::from_raw_fd(fd) };
    // SAFETY: sockaddr_vm is plain data; all-zero is a valid starting value.
    let mut addr: libc::sockaddr_vm = unsafe { std::mem::zeroed() };
    let len = std::mem::size_of::<libc::sockaddr_vm>();
    addr.svm_len = len as u8;
    addr.svm_family = libc::AF_VSOCK as libc::sa_family_t;
    addr.svm_port = port;
    addr.svm_cid = cid;
    // SAFETY: addr outlives the call and len is its exact size.
    let rc = unsafe {
        libc::connect(
            fd,
            (&raw const addr).cast::<libc::sockaddr>(),
            len as libc::socklen_t,
        )
    };
    if rc != 0 {
        return Err(std::io::Error::last_os_error());
    }
    Ok(owned)
}

pub fn set_clock(when: SystemTime) -> std::io::Result<()> {
    let since = when
        .duration_since(SystemTime::UNIX_EPOCH)
        .map_err(std::io::Error::other)?;
    let tv = libc::timeval {
        tv_sec: libc::time_t::try_from(since.as_secs()).map_err(std::io::Error::other)?,
        tv_usec: since.subsec_micros() as libc::suseconds_t,
    };
    // SAFETY: tv is a valid timeval for the duration of the call; no timezone is passed.
    let rc = unsafe { libc::settimeofday(&raw const tv, std::ptr::null()) };
    if rc != 0 {
        return Err(std::io::Error::last_os_error());
    }
    Ok(())
}

pub fn shutdown_command(reboot: bool, _force: bool) -> (&'static str, Vec<&'static str>) {
    (
        "/sbin/shutdown",
        vec![if reboot { "-r" } else { "-h" }, "now"],
    )
}

/// Parses `lsof -nP -F pcPn` output into listening ports.
fn parse_lsof(text: &str) -> Vec<ListeningPort> {
    let mut ports = Vec::new();
    let (mut command, mut proto) = (None::<String>, None);
    for line in text.lines() {
        let (tag, value) = line.split_at(line.len().min(1));
        match tag {
            "p" => command = None,
            "c" => command = Some(value.to_owned()),
            "P" => {
                proto = match value {
                    "TCP" => Some(PortProto::Tcp),
                    "UDP" => Some(PortProto::Udp),
                    _ => None,
                }
            }
            "n" if !value.contains("->") => {
                let (Some(proto), Some((host, port))) = (proto, value.rsplit_once(':')) else {
                    continue;
                };
                let Ok(port) = port.parse() else { continue };
                let address = match host.trim_matches(|c| c == '[' || c == ']') {
                    "*" => "0.0.0.0".to_owned(),
                    other => other.to_owned(),
                };
                ports.push(ListeningPort {
                    proto,
                    address,
                    port,
                    process: command.clone(),
                });
            }
            _ => {}
        }
    }
    ports
}

pub fn listening_ports() -> std::io::Result<Vec<ListeningPort>> {
    let out = Command::new("/usr/sbin/lsof")
        .args(["-nP", "-F", "pcPn", "-iTCP", "-sTCP:LISTEN", "-iUDP"])
        .output()?;
    Ok(parse_lsof(&String::from_utf8_lossy(&out.stdout)))
}

/// macOS has no file system freeze: flush to disk, which is not a consistency point. Nothing to thaw.
pub fn freeze() -> std::io::Result<Vec<String>> {
    nix::unistd::sync();
    Ok(Vec::new())
}

pub fn thaw(_frozen: &[String]) -> Vec<String> {
    Vec::new()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_lsof_fields() {
        let text = "p1\ncsshd\nf3\nPTCP\nn*:22\nf4\nPTCP\nn[::1]:631\np2\ncmDNSResponder\nf5\nPUDP\nn*:5353\nf6\nPUDP\nn10.0.0.2:5000->10.0.0.1:53\n";
        let ports = parse_lsof(text);
        assert_eq!(ports.len(), 3);
        assert_eq!(
            (
                ports[0].address.as_str(),
                ports[0].port,
                ports[0].process.as_deref()
            ),
            ("0.0.0.0", 22, Some("sshd"))
        );
        assert_eq!((ports[1].address.as_str(), ports[1].port), ("::1", 631));
        assert_eq!(
            (ports[2].proto, ports[2].port, ports[2].process.as_deref()),
            (PortProto::Udp, 5353, Some("mDNSResponder"))
        );
    }
}
