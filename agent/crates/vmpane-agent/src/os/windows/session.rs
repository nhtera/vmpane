//! Starting the user-session helper on Windows. The service runs as LocalSystem in session 0; the helper must
//! run as the logged-in user on the interactive desktop, so the service launches it there itself
//! (`WTSQueryUserToken` + `CreateProcessAsUserW`) and hands it a named pipe whose server only accepts that
//! process.

use std::path::Path;

use windows::Win32::Foundation::{CloseHandle, HANDLE, WAIT_OBJECT_0};
use windows::Win32::Security::{
    DuplicateTokenEx, SecurityImpersonation, TOKEN_ALL_ACCESS, TokenPrimary,
};
use windows::Win32::System::Environment::{CreateEnvironmentBlock, DestroyEnvironmentBlock};
use windows::Win32::System::Pipes::GetNamedPipeClientProcessId;
use windows::Win32::System::RemoteDesktop::{WTSGetActiveConsoleSessionId, WTSQueryUserToken};
use windows::Win32::System::Threading::{
    CREATE_NO_WINDOW, CREATE_UNICODE_ENVIRONMENT, CreateProcessAsUserW, PROCESS_INFORMATION,
    STARTUPINFOW, TerminateProcess, WaitForSingleObject,
};
use windows::core::{PWSTR, w};

/// The session at the physical console, if someone is logged in there.
pub fn console_session() -> Option<u32> {
    // SAFETY: no arguments; returns 0xFFFFFFFF without a console session.
    let id = unsafe { WTSGetActiveConsoleSessionId() };
    (id != u32::MAX).then_some(id)
}

/// A helper process started in a user session.
pub struct Helper {
    pub pid: u32,
    process: HANDLE,
}

// SAFETY: a process handle may be waited on and terminated from any thread.
unsafe impl Send for Helper {}
unsafe impl Sync for Helper {}

impl Helper {
    /// Blocks until the process exits (call off the async runtime).
    pub fn wait(&self) {
        // SAFETY: the handle is open until `Drop`.
        unsafe {
            let _ = WaitForSingleObject(self.process, u32::MAX) == WAIT_OBJECT_0;
        }
    }

    pub fn kill(&self) {
        // SAFETY: as above; terminating an exited process fails harmlessly.
        unsafe {
            let _ = TerminateProcess(self.process, 1);
        }
    }
}

impl Drop for Helper {
    fn drop(&mut self) {
        // SAFETY: closed exactly once.
        unsafe {
            let _ = CloseHandle(self.process);
        }
    }
}

/// Starts `exe session --socket <pipe>` as the user logged in to `session`, on its interactive desktop.
pub fn launch(session: u32, exe: &Path, pipe: &str) -> std::io::Result<Helper> {
    let mut command: Vec<u16> = format!("\"{}\" session --socket \"{pipe}\"", exe.display())
        .encode_utf16()
        .chain([0])
        .collect();
    // SAFETY: every handle and buffer below lives across the calls that use it and is released once.
    unsafe {
        let mut user = HANDLE::default();
        WTSQueryUserToken(session, &mut user).map_err(std::io::Error::other)?;
        let mut primary = HANDLE::default();
        let duplicated = DuplicateTokenEx(
            user,
            TOKEN_ALL_ACCESS,
            None,
            SecurityImpersonation,
            TokenPrimary,
            &mut primary,
        );
        let _ = CloseHandle(user);
        duplicated.map_err(std::io::Error::other)?;
        let mut environment = std::ptr::null_mut();
        let have_environment =
            CreateEnvironmentBlock(&mut environment, Some(primary), false).is_ok();
        let startup = STARTUPINFOW {
            cb: std::mem::size_of::<STARTUPINFOW>() as u32,
            lpDesktop: PWSTR(w!("winsta0\\default").as_ptr().cast_mut()),
            ..Default::default()
        };
        let mut info = PROCESS_INFORMATION::default();
        let created = CreateProcessAsUserW(
            Some(primary),
            None,
            Some(PWSTR(command.as_mut_ptr())),
            None,
            None,
            false,
            CREATE_UNICODE_ENVIRONMENT | CREATE_NO_WINDOW,
            have_environment.then_some(environment.cast_const()),
            None,
            &startup,
            &mut info,
        );
        if have_environment {
            let _ = DestroyEnvironmentBlock(environment);
        }
        let _ = CloseHandle(primary);
        created.map_err(std::io::Error::other)?;
        let _ = CloseHandle(info.hThread);
        Ok(Helper {
            pid: info.dwProcessId,
            process: info.hProcess,
        })
    }
}

/// The process id at the other end of a connected pipe server.
pub fn pipe_client_pid(pipe: &tokio::net::windows::named_pipe::NamedPipeServer) -> Option<u32> {
    use std::os::windows::io::AsRawHandle;
    let mut pid = 0u32;
    // SAFETY: the pipe handle is open for the duration of the call.
    unsafe { GetNamedPipeClientProcessId(HANDLE(pipe.as_raw_handle()), &mut pid) }.ok()?;
    Some(pid)
}
