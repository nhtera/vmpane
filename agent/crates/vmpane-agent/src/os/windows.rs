//! Windows guests. Built and tested on the CI's windows-11-arm runner (no local MSVC toolchain).

use std::os::windows::process::CommandExt;
use std::path::Path;
use std::process::ExitStatus;
use std::time::SystemTime;

use vmpane_agent_proto::jsonrpc::ErrorObject;
use vmpane_agent_proto::methods::{ExecStartParams, SessionState, Signal};
use windows::Win32::Foundation::{FILETIME, SYSTEMTIME};
use windows::Win32::System::SystemInformation::SetSystemTime;
use windows::Win32::System::Time::FileTimeToSystemTime;

pub mod clipboard;
mod drag;
mod net;
pub mod serial;
pub mod service;
pub mod session;
mod uia;
pub use drag::drag_probe;
pub use net::{interfaces, listening_ports};
pub use uia::screen_elements;

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

/// Nothing is handed to the system on Windows: the job holds what the launch starts.
pub struct AppLaunch;

pub fn desktop_params(
    params: ExecStartParams,
) -> Result<(ExecStartParams, Option<AppLaunch>), ErrorObject> {
    Ok((params, None))
}

/// The session helper runs on the user's desktop; a console program gets a console window of its own there.
pub async fn desktop_environment(
    cmd: &mut tokio::process::Command,
    _params: &ExecStartParams,
) -> Result<(), ErrorObject> {
    cmd.creation_flags(CREATE_NEW_PROCESS_GROUP);
    Ok(())
}

/// A desktop launch: a job holding the process and everything it starts (`cmd /c` ends at once, its program
/// stays), so ending the launch ends them all. Closing the job leaves them running.
pub struct DesktopTree {
    job: windows::Win32::Foundation::HANDLE,
}

// SAFETY: a job handle may be used and closed from any thread.
unsafe impl Send for DesktopTree {}
unsafe impl Sync for DesktopTree {}

impl DesktopTree {
    pub fn adopt(
        child: &tokio::process::Child,
        _pid: u32,
        _app: Option<AppLaunch>,
    ) -> std::io::Result<DesktopTree> {
        use windows::Win32::Foundation::{CloseHandle, HANDLE};
        use windows::Win32::System::JobObjects::{AssignProcessToJobObject, CreateJobObjectW};
        let process = child
            .raw_handle()
            .ok_or_else(|| std::io::Error::other("the app already ended"))?;
        // SAFETY: the job is new and owned here; the process handle is the child's, open while it is borrowed.
        unsafe {
            let job = CreateJobObjectW(None, None).map_err(std::io::Error::other)?;
            if let Err(err) = AssignProcessToJobObject(job, HANDLE(process)) {
                let _ = CloseHandle(job);
                return Err(std::io::Error::other(err));
            }
            Ok(DesktopTree { job })
        }
    }

    /// Whether a process of the job still runs.
    pub fn alive(&self) -> bool {
        use windows::Win32::System::JobObjects::{
            JOBOBJECT_BASIC_ACCOUNTING_INFORMATION, JobObjectBasicAccountingInformation,
            QueryInformationJobObject,
        };
        let mut info = JOBOBJECT_BASIC_ACCOUNTING_INFORMATION::default();
        // SAFETY: the job is open until `Drop`; the buffer is the struct the class asks for.
        let queried = unsafe {
            QueryInformationJobObject(
                Some(self.job),
                JobObjectBasicAccountingInformation,
                (&raw mut info).cast(),
                std::mem::size_of::<JOBOBJECT_BASIC_ACCOUNTING_INFORMATION>() as u32,
                None,
            )
        };
        queried.is_ok() && info.ActiveProcesses > 0
    }

    pub fn signal(&self, _signal: Signal) {
        // SAFETY: the job is open until `Drop`.
        unsafe {
            let _ = windows::Win32::System::JobObjects::TerminateJobObject(self.job, 1);
        }
    }
}

impl Drop for DesktopTree {
    fn drop(&mut self) {
        // SAFETY: closed exactly once; without JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE its processes keep running.
        unsafe {
            let _ = windows::Win32::Foundation::CloseHandle(self.job);
        }
    }
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

/// Selects `path` in Explorer.
pub fn reveal(path: &Path) -> std::io::Result<()> {
    std::process::Command::new("explorer.exe")
        .raw_arg(format!("/select,\"{}\"", path.display()))
        .spawn()?;
    Ok(())
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

/// The console session as Windows keeps it (`WTSSessionInfoEx`): no user name is the sign-in screen; else its
/// lock flag, which only Winlogon sets.
pub fn session_state() -> SessionState {
    use windows::Win32::System::RemoteDesktop::{
        WTS_CURRENT_SERVER_HANDLE, WTS_SESSIONSTATE_LOCK, WTS_SESSIONSTATE_UNLOCK, WTSFreeMemory,
        WTSINFOEXW, WTSQuerySessionInformationW, WTSSessionInfoEx,
    };
    use windows::core::PWSTR;
    let Some(id) = session::console_session() else {
        return SessionState::Unknown;
    };
    let mut buffer = PWSTR::null();
    let mut bytes = 0u32;
    // SAFETY: the buffer comes from the call, is read as the WTSINFOEXW it is when large enough, and is freed once.
    unsafe {
        if WTSQuerySessionInformationW(
            Some(WTS_CURRENT_SERVER_HANDLE),
            id,
            WTSSessionInfoEx,
            &mut buffer,
            &mut bytes,
        )
        .is_err()
            || buffer.is_null()
        {
            return SessionState::Unknown;
        }
        let state = if (bytes as usize) < std::mem::size_of::<WTSINFOEXW>() {
            SessionState::Unknown
        } else {
            let info = &*buffer.0.cast::<WTSINFOEXW>();
            let level1 = &info.Data.WTSInfoExLevel1;
            let user = &level1.UserName;
            let named = user.iter().take_while(|c| **c != 0).count() > 0;
            match (info.Level, named, level1.SessionFlags as u32) {
                (1, false, _) => SessionState::Greeter,
                (1, true, WTS_SESSIONSTATE_LOCK) => SessionState::Locked,
                (1, true, WTS_SESSIONSTATE_UNLOCK) => SessionState::Unlocked,
                _ => SessionState::Unknown,
            }
        };
        WTSFreeMemory(buffer.0.cast());
        state
    }
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
