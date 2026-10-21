//! `screen.elements`: the controls of the user's foreground window, read by the user-session helper (UI
//! Automation on Windows, the accessibility API on macOS once the user has granted it). The daemon relays the
//! request to the helper, as it does `session.reveal`.

use vmpane_agent_proto::error::ErrorCode;
use vmpane_agent_proto::jsonrpc::ErrorObject;
use vmpane_agent_proto::limits::{SCREEN_MAX_ELEMENTS, SCREEN_MAX_NAME};
use vmpane_agent_proto::methods::{ScreenElements, ScreenElementsParams};

use crate::connection::Reply;

/// Whether this build can list controls ([`vmpane_agent_proto::methods::cap::SCREEN`]).
pub const SUPPORTED: bool = cfg!(any(windows, target_os = "macos"));

/// Reads them off the runtime thread (a large window takes up to a second), names cut to
/// [`SCREEN_MAX_NAME`] characters.
pub async fn elements(params: ScreenElementsParams) -> Result<Reply, ErrorObject> {
    let max = match params.max_elements {
        0 => SCREEN_MAX_ELEMENTS,
        n => n.min(SCREEN_MAX_ELEMENTS),
    } as usize;
    let mut found = tokio::task::spawn_blocking(move || read(max))
        .await
        .map_err(|_| ErrorObject::new(ErrorCode::InternalError, "the screen reader stopped"))??;
    for element in &mut found.elements {
        element.name = cut(&element.name);
        element.value = element.value.as_deref().map(cut);
    }
    Reply::ok(&found)
}

/// Controls worth listing even without a name (an unnamed edit box is still where text goes).
pub fn interactive(role: &str) -> bool {
    matches!(
        role,
        "button" | "edit" | "checkbox" | "radiobutton" | "combobox" | "slider" | "spinner"
    )
}

fn cut(text: &str) -> String {
    text.trim().chars().take(SCREEN_MAX_NAME).collect()
}

#[cfg(windows)]
fn read(max: usize) -> Result<ScreenElements, ErrorObject> {
    crate::os::screen_elements(max)
        .map_err(|err| ErrorObject::new(ErrorCode::InternalError, format!("UI Automation: {err}")))
}

/// What `vmpane-agent screen-elements` prints (macOS).
#[cfg(target_os = "macos")]
#[derive(serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
enum ChildRead {
    Elements(ScreenElements),
    NotTrusted,
    Failed(String),
}

/// `vmpane-agent screen-elements <max>`: reads the controls and prints the result. The session helper reads them
/// in such a child, new each time: macOS keeps a running process's first answer to whether it may use
/// Accessibility, so a grant given while the helper runs reached only processes started after it.
#[cfg(target_os = "macos")]
pub fn print_elements(max: usize) -> std::process::ExitCode {
    let read = match crate::os::screen_elements(max) {
        Ok(found) => ChildRead::Elements(found),
        Err(crate::os::AxError::NotTrusted) => ChildRead::NotTrusted,
        Err(crate::os::AxError::Other(message)) => ChildRead::Failed(message),
    };
    println!("{}", serde_json::to_string(&read).unwrap_or_default());
    std::process::ExitCode::SUCCESS
}

#[cfg(target_os = "macos")]
fn read(max: usize) -> Result<ScreenElements, ErrorObject> {
    use std::io::Read;
    use std::process::{Command, Stdio};
    use std::time::{Duration, Instant};
    let failed = |message: String| ErrorObject::new(ErrorCode::InternalError, message);
    let exe =
        std::env::current_exe().map_err(|err| failed(format!("cannot find the agent: {err}")))?;
    let mut child = Command::new(exe)
        .args(["screen-elements", &max.to_string()])
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|err| failed(format!("cannot start the screen reader: {err}")))?;
    // Read while it runs: a large answer would otherwise fill the pipe and stop it.
    let mut stdout = child
        .stdout
        .take()
        .ok_or_else(|| failed("no output".into()))?;
    let output = std::thread::spawn(move || {
        let mut text = String::new();
        let _ = stdout.read_to_string(&mut text);
        text
    });
    let deadline = Instant::now() + Duration::from_secs(10);
    while child.try_wait().ok().flatten().is_none() {
        if Instant::now() > deadline {
            let _ = child.kill();
            let _ = child.wait();
            return Err(failed("the app in front did not answer in time".into()));
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    let text = output.join().unwrap_or_default();
    match serde_json::from_str::<ChildRead>(text.trim()) {
        Ok(ChildRead::Elements(found)) => Ok(found),
        Ok(ChildRead::NotTrusted) => Err(ErrorObject::new(
            ErrorCode::PermissionDenied,
            "Grant Accessibility to VMPane Agent in the VM: System Settings › Privacy & Security › \
             Accessibility, turn on vmpane-agent",
        )),
        Ok(ChildRead::Failed(message)) => Err(failed(message)),
        Err(_) => Err(failed("the screen reader stopped".into())),
    }
}

#[cfg(not(any(windows, target_os = "macos")))]
fn read(_max: usize) -> Result<ScreenElements, ErrorObject> {
    Err(ErrorObject::new(
        ErrorCode::CapUnsupported,
        "this guest cannot list its controls",
    ))
}
