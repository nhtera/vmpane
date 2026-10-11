//! Windows guests. Built and tested on the CI's windows-11-arm runner (no local MSVC toolchain).

use std::os::windows::process::CommandExt;
use std::path::Path;
use std::process::ExitStatus;
use std::time::SystemTime;

use vmpane_agent_proto::methods::Signal;
use windows::Win32::Foundation::{FILETIME, SYSTEMTIME};
use windows::Win32::System::SystemInformation::SetSystemTime;
use windows::Win32::System::Time::FileTimeToSystemTime;

mod net;
pub use net::{interfaces, listening_ports};

pub const HAS_NET_INFO: bool = true;

const CREATE_NO_WINDOW: u32 = 0x0800_0000;
const CREATE_NEW_PROCESS_GROUP: u32 = 0x0000_0200;

/// "10.0.26100.1" from `ver`.
pub fn os_version() -> String {
    let out = std::process::Command::new("cmd.exe")
        .args(["/d", "/c", "ver"])
        .creation_flags(CREATE_NO_WINDOW)
        .output();
    let text = out
        .map(|o| String::from_utf8_lossy(&o.stdout).into_owned())
        .unwrap_or_default();
    text.split("Version ")
        .nth(1)
        .map(|v| v.trim().trim_end_matches(']').to_owned())
        .unwrap_or_default()
}

pub fn default_gateway() -> Option<String> {
    None
}

/// Kills the process and its children (`taskkill /T /F`); Windows has no gentler equivalent for a tree.
pub fn signal_tree(pid: u32, _signal: Signal) {
    if pid == 0 {
        return;
    }
    let _ = std::process::Command::new("taskkill.exe")
        .args(["/T", "/F", "/PID", &pid.to_string()])
        .creation_flags(CREATE_NO_WINDOW)
        .output();
}

pub fn shell_command(shell: &str) -> tokio::process::Command {
    let mut cmd = tokio::process::Command::new("cmd.exe");
    cmd.raw_arg(format!("/d /s /c \"{shell}\""));
    cmd
}

pub fn own_process_group(cmd: &mut tokio::process::Command) {
    cmd.creation_flags(CREATE_NO_WINDOW | CREATE_NEW_PROCESS_GROUP);
}

pub fn exit_parts(status: &ExitStatus) -> (Option<i32>, Option<String>) {
    (status.code(), None)
}

pub async fn create_private(path: &Path) -> std::io::Result<tokio::fs::File> {
    tokio::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(path)
        .await
}

pub fn set_mode(_path: &Path, _mode: u32) -> std::io::Result<()> {
    Ok(())
}

pub fn mode_of(_meta: &std::fs::Metadata) -> u32 {
    0
}

pub fn create_private_dir(path: &Path) -> std::io::Result<()> {
    std::fs::create_dir(path)
}

pub fn open_serial(path: &Path) -> std::io::Result<std::fs::File> {
    std::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .open(path)
}

pub fn set_clock(when: SystemTime) -> std::io::Result<()> {
    // FILETIME counts 100 ns intervals since 1601-01-01.
    const EPOCH_DIFF_100NS: u64 = 116_444_736_000_000_000;
    let since = when
        .duration_since(SystemTime::UNIX_EPOCH)
        .map_err(std::io::Error::other)?;
    let ticks =
        EPOCH_DIFF_100NS + u64::try_from(since.as_nanos() / 100).map_err(std::io::Error::other)?;
    let file_time = FILETIME {
        dwLowDateTime: ticks as u32,
        dwHighDateTime: (ticks >> 32) as u32,
    };
    let mut system_time = SYSTEMTIME::default();
    // SAFETY: both structs live across the calls; the APIs only read/write them.
    unsafe {
        FileTimeToSystemTime(&file_time, &mut system_time).map_err(std::io::Error::other)?;
        SetSystemTime(&system_time).map_err(std::io::Error::other)?;
    }
    Ok(())
}

pub fn shutdown_command(reboot: bool, force: bool) -> (&'static str, Vec<&'static str>) {
    let mut args = vec![if reboot { "/r" } else { "/s" }, "/t", "0"];
    if force {
        args.push("/f");
    }
    ("shutdown.exe", args)
}

/// No volume freeze without VSS: nothing frozen, nothing to thaw.
pub fn freeze() -> std::io::Result<Vec<String>> {
    Ok(Vec::new())
}

pub fn thaw_stale() -> Vec<String> {
    Vec::new()
}

pub fn thaw(_frozen: &[String]) -> Vec<String> {
    Vec::new()
}
