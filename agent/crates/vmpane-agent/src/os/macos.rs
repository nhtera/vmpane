//! macOS guests.

mod ax;
pub mod clipboard;

pub use ax::{AxError, screen_elements};

use std::os::fd::{FromRawFd, OwnedFd};
use std::process::Command;
use std::time::SystemTime;

use vmpane_agent_proto::error::ErrorCode;
use vmpane_agent_proto::jsonrpc::ErrorObject;
use vmpane_agent_proto::methods::{ExecStartParams, ListeningPort, PortProto, SessionState};

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

/// Whether `uid` is the user logged in at the console (owner of /dev/console).
pub fn is_console_user(uid: u32) -> bool {
    use std::os::unix::fs::MetadataExt;
    std::fs::metadata("/dev/console").is_ok_and(|m| m.uid() == uid && uid != 0)
}

/// An app bundle's path as `argv[0]` opens the app (as a new instance) through LaunchServices: macOS refuses
/// its own apps started any other way (launch constraints). The launch then follows the app's instances.
pub fn desktop_params(
    mut params: ExecStartParams,
) -> Result<(ExecStartParams, Option<super::AppLaunch>), ErrorObject> {
    use objc2_foundation::{NSBundle, NSString};
    let Some(first) = params.argv.first().cloned() else {
        return Ok((params, None));
    };
    if !first.trim_end_matches('/').ends_with(".app") {
        return Ok((params, None));
    }
    let executable = NSBundle::bundleWithPath(&NSString::from_str(&first))
        .and_then(|bundle| bundle.executablePath())
        .map(|path| std::path::PathBuf::from(path.to_string()))
        .ok_or_else(|| ErrorObject::new(ErrorCode::NotFound, format!("{first} is not an app")))?;
    let executable = executable.canonicalize().unwrap_or(executable);
    let mut argv = vec![
        "/usr/bin/open".to_owned(),
        "-n".to_owned(),
        "-a".to_owned(),
        first,
    ];
    if params.argv.len() > 1 {
        argv.push("--args".to_owned());
        argv.extend(params.argv.drain(1..));
    }
    params.argv = argv;
    let before = pids_running(&executable);
    Ok((params, Some(super::AppLaunch { executable, before })))
}

/// Processes running `executable` (by their executable's path).
pub fn pids_running(executable: &std::path::Path) -> Vec<i32> {
    let mut pids = vec![0i32; 4096];
    let size = i32::try_from(pids.len() * std::mem::size_of::<i32>()).unwrap_or(i32::MAX);
    // SAFETY: the buffer holds `size` bytes; the call returns how many pids it wrote.
    let count = unsafe { libc::proc_listallpids(pids.as_mut_ptr().cast(), size) };
    pids.truncate(usize::try_from(count).unwrap_or(0));
    pids.into_iter()
        .filter(|pid| *pid > 0)
        .filter(|pid| {
            let mut path = [0u8; libc::PROC_PIDPATHINFO_MAXSIZE as usize];
            // SAFETY: the buffer is as large as the call may fill.
            let length =
                unsafe { libc::proc_pidpath(*pid, path.as_mut_ptr().cast(), path.len() as u32) };
            usize::try_from(length).is_ok_and(|n| {
                n > 0 && std::path::Path::new(&*String::from_utf8_lossy(&path[..n])) == executable
            })
        })
        .collect()
}

/// The session helper runs in the user's GUI session: its environment is the desktop's.
pub async fn desktop_environment(
    _cmd: &mut tokio::process::Command,
    _params: &ExecStartParams,
) -> Result<(), ErrorObject> {
    Ok(())
}

/// The console as the system has it: the login window while root owns /dev/console; otherwise the console
/// user's entry in the I/O Registry's `IOConsoleUsers`, which WindowServer keeps (only root can change the
/// registry root's properties), locked when it has `CGSSessionScreenIsLocked`.
pub fn session_state() -> SessionState {
    use std::os::unix::fs::MetadataExt;
    let Ok(console) = std::fs::metadata("/dev/console") else {
        return SessionState::Unknown;
    };
    if console.uid() == 0 {
        return SessionState::Greeter;
    }
    match console_user_locked(console.uid()) {
        Some(true) => SessionState::Locked,
        Some(false) => SessionState::Unlocked,
        None => SessionState::Unknown,
    }
}

/// Whether `uid`'s console session shows the lock screen; None when the registry has no such session.
fn console_user_locked(uid: u32) -> Option<bool> {
    use std::ptr::NonNull;

    use objc2_core_foundation::{
        CFArray, CFBoolean, CFDictionary, CFNumber, CFRetained, CFString, CFType,
    };
    #[link(name = "IOKit", kind = "framework")]
    unsafe extern "C" {
        fn IORegistryGetRootEntry(main_port: u32) -> u32;
        fn IORegistryEntryCreateCFProperty(
            entry: u32,
            key: &CFString,
            allocator: *const std::ffi::c_void,
            options: u32,
        ) -> *mut CFType;
        fn IOObjectRelease(object: u32) -> i32;
    }
    // SAFETY: the root entry is released once after the copy; the property comes back retained (a create call).
    let users = unsafe {
        let root = IORegistryGetRootEntry(0);
        if root == 0 {
            return None;
        }
        let key = CFString::from_static_str("IOConsoleUsers");
        let value = IORegistryEntryCreateCFProperty(root, &key, std::ptr::null(), 0);
        IOObjectRelease(root);
        CFRetained::from_raw(NonNull::new(value)?)
    };
    let users = users.downcast::<CFArray>().ok()?;
    // SAFETY: an array of CF objects; each is checked to be a dictionary before use.
    for user in unsafe { users.cast_unchecked::<CFType>() }.iter() {
        let Some(user) = user.downcast_ref::<CFDictionary>() else {
            continue;
        };
        // SAFETY: the keys of IOConsoleUsers entries are strings; values are checked by type below.
        let user = unsafe { user.cast_unchecked::<CFString, CFType>() };
        let get = |key: &'static str| user.get(&CFString::from_static_str(key));
        let number = get("kCGSSessionUserIDKey");
        let id = number
            .as_ref()
            .and_then(|n| n.downcast_ref::<CFNumber>()?.as_i64());
        let flag = |key| get(key).and_then(|v| Some(v.downcast_ref::<CFBoolean>()?.as_bool()));
        if id == Some(i64::from(uid)) && flag("kCGSSessionOnConsoleKey") == Some(true) {
            return Some(flag("CGSSessionScreenIsLocked") == Some(true));
        }
    }
    None
}

/// Selects `path` in Finder.
pub fn reveal(path: &std::path::Path) -> std::io::Result<()> {
    let status = Command::new("/usr/bin/open").arg("-R").arg(path).status()?;
    if status.success() {
        Ok(())
    } else {
        Err(std::io::Error::other("open -R failed"))
    }
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

pub fn thaw_stale() -> Vec<String> {
    Vec::new()
}

pub fn thaw(_frozen: &[String]) -> Vec<String> {
    Vec::new()
}

/// Whether this process's parent runs the same executable (the session helper starting its screen reader).
pub fn parent_is_this_program() -> bool {
    let mut path = [0u8; libc::PROC_PIDPATHINFO_MAXSIZE as usize];
    // SAFETY: the buffer is as large as the call may fill.
    let length =
        unsafe { libc::proc_pidpath(libc::getppid(), path.as_mut_ptr().cast(), path.len() as u32) };
    let Ok(length) = usize::try_from(length) else {
        return false;
    };
    let parent = std::path::PathBuf::from(String::from_utf8_lossy(&path[..length]).into_owned());
    match (
        std::env::current_exe().and_then(|p| p.canonicalize()),
        parent.canonicalize(),
    ) {
        (Ok(this), Ok(parent)) => this == parent,
        _ => false,
    }
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
