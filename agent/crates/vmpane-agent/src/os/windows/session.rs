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

/// Starts `exe session --once --socket <pipe>` (it exits when the service closes the pipe) as the user logged in to `session`, on its interactive desktop.
pub fn launch(session: u32, exe: &Path, pipe: &str) -> std::io::Result<Helper> {
    let mut command: Vec<u16> = format!("\"{}\" session --once --socket \"{pipe}\"", exe.display())
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

/// The string SID of the user logged in to `session`.
pub fn user_sid(session: u32) -> std::io::Result<String> {
    use windows::Win32::Foundation::{HLOCAL, LocalFree};
    use windows::Win32::Security::Authorization::ConvertSidToStringSidW;
    use windows::Win32::Security::{GetTokenInformation, TOKEN_USER, TokenUser};
    // SAFETY: the token and buffers live across the calls; the string is freed with LocalFree once.
    unsafe {
        let mut token = HANDLE::default();
        WTSQueryUserToken(session, &mut token).map_err(std::io::Error::other)?;
        let mut needed = 0u32;
        let _ = GetTokenInformation(token, TokenUser, None, 0, &mut needed);
        let mut buffer = vec![0u64; (needed as usize).div_ceil(8).max(1)];
        let read = GetTokenInformation(
            token,
            TokenUser,
            Some(buffer.as_mut_ptr().cast()),
            needed,
            &mut needed,
        );
        let _ = CloseHandle(token);
        read.map_err(std::io::Error::other)?;
        let user = &*buffer.as_ptr().cast::<TOKEN_USER>();
        let mut text = PWSTR::null();
        ConvertSidToStringSidW(user.User.Sid, &mut text).map_err(std::io::Error::other)?;
        let sid = text.to_string().map_err(std::io::Error::other);
        let _ = LocalFree(Some(HLOCAL(text.0.cast())));
        sid
    }
}

/// A pipe server that only SYSTEM and the user `sid` may open (read and write), as the first instance of its
/// name: the default descriptor would let the user only read, and anyone connect first.
pub fn create_pipe(
    name: &str,
    sid: &str,
) -> std::io::Result<tokio::net::windows::named_pipe::NamedPipeServer> {
    use windows::Win32::Foundation::{HLOCAL, LocalFree};
    use windows::Win32::Security::Authorization::{
        ConvertStringSecurityDescriptorToSecurityDescriptorW, SDDL_REVISION_1,
    };
    use windows::Win32::Security::{PSECURITY_DESCRIPTOR, SECURITY_ATTRIBUTES};
    use windows::core::HSTRING;
    let sddl = HSTRING::from(format!("D:P(A;;GA;;;SY)(A;;GRGW;;;{sid})"));
    // SAFETY: the descriptor lives until LocalFree, after the pipe was created from it.
    unsafe {
        let mut descriptor = PSECURITY_DESCRIPTOR::default();
        ConvertStringSecurityDescriptorToSecurityDescriptorW(
            &sddl,
            SDDL_REVISION_1,
            &mut descriptor,
            None,
        )
        .map_err(std::io::Error::other)?;
        let mut attributes = SECURITY_ATTRIBUTES {
            nLength: std::mem::size_of::<SECURITY_ATTRIBUTES>() as u32,
            lpSecurityDescriptor: descriptor.0,
            bInheritHandle: false.into(),
        };
        let server = tokio::net::windows::named_pipe::ServerOptions::new()
            .first_pipe_instance(true)
            .reject_remote_clients(true)
            .create_with_security_attributes_raw(name, (&raw mut attributes).cast());
        let _ = LocalFree(Some(HLOCAL(descriptor.0)));
        server
    }
}

/// 16 random bytes as hex: pipe names nobody can take ahead.
pub fn random_hex() -> String {
    use windows::Win32::Security::Cryptography::{
        BCRYPT_USE_SYSTEM_PREFERRED_RNG, BCryptGenRandom,
    };
    let mut bytes = [0u8; 16];
    // SAFETY: the buffer is valid for its length.
    let _ = unsafe { BCryptGenRandom(None, &mut bytes, BCRYPT_USE_SYSTEM_PREFERRED_RNG) };
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// Per-Monitor-V2 DPI awareness for this process (the session helper), so UI Automation's rectangles are the
/// display's pixels. A failure (already set) leaves the process as it is.
pub fn use_physical_pixels() {
    use windows::Win32::UI::HiDpi::{
        DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2, SetProcessDpiAwarenessContext,
    };
    // SAFETY: no pointers; it only changes how this process is told about coordinates.
    if let Err(err) =
        unsafe { SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2) }
    {
        tracing::warn!(%err, "cannot make the session helper DPI aware");
    }
}
