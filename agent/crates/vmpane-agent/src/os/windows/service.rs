//! Running as a Windows service (`vmpane-agent --service`, installed by the MSI as LocalSystem, automatic
//! start). The service control handler turns Stop/Shutdown into the daemon's stop and session changes into a
//! restart of the user-session helper.

use std::ffi::OsString;
use std::sync::{Mutex, OnceLock};
use std::time::Duration;

use tokio::sync::{mpsc, oneshot};
use windows_service::service::{
    ServiceControl, ServiceControlAccept, ServiceExitCode, ServiceState, ServiceStatus, ServiceType,
};
use windows_service::service_control_handler::{self, ServiceControlHandlerResult};
use windows_service::{define_windows_service, service_dispatcher};

pub const NAME: &str = "vmpane-agent";

/// What the service control manager tells the daemon.
pub struct Signals {
    pub stop: oneshot::Receiver<()>,
    pub sessions: mpsc::UnboundedReceiver<()>,
}

type Body = Box<dyn FnOnce(Signals) + Send>;

static BODY: OnceLock<Mutex<Option<Body>>> = OnceLock::new();

define_windows_service!(ffi_service_main, service_main);

/// Runs `body` as the service; returns false when the process was not started by the SCM.
pub fn run(body: impl FnOnce(Signals) + Send + 'static) -> bool {
    let _ = BODY.set(Mutex::new(Some(Box::new(body))));
    service_dispatcher::start(NAME, ffi_service_main).is_ok()
}

fn service_main(_args: Vec<OsString>) {
    let Some(body) = BODY.get().and_then(|b| b.lock().ok()?.take()) else {
        return;
    };
    let (stop_tx, stop) = oneshot::channel();
    let stop_tx = Mutex::new(Some(stop_tx));
    let (session_tx, sessions) = mpsc::unbounded_channel();
    let handler = move |control| match control {
        ServiceControl::Stop | ServiceControl::Shutdown => {
            if let Some(tx) = stop_tx.lock().ok().and_then(|mut tx| tx.take()) {
                let _ = tx.send(());
            }
            ServiceControlHandlerResult::NoError
        }
        ServiceControl::SessionChange(_) => {
            let _ = session_tx.send(());
            ServiceControlHandlerResult::NoError
        }
        ServiceControl::Interrogate => ServiceControlHandlerResult::NoError,
        _ => ServiceControlHandlerResult::NotImplemented,
    };
    let Ok(status) = service_control_handler::register(NAME, handler) else {
        return;
    };
    let set = |state, accept| {
        let _ = status.set_service_status(ServiceStatus {
            service_type: ServiceType::OWN_PROCESS,
            current_state: state,
            controls_accepted: accept,
            exit_code: ServiceExitCode::Win32(0),
            checkpoint: 0,
            wait_hint: Duration::from_secs(10),
            process_id: None,
        });
    };
    set(
        ServiceState::Running,
        ServiceControlAccept::STOP
            | ServiceControlAccept::SHUTDOWN
            | ServiceControlAccept::SESSION_CHANGE,
    );
    body(Signals { stop, sessions });
    set(ServiceState::Stopped, ServiceControlAccept::empty());
}
