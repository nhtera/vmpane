//! Logging to stderr (journald, launchd and the service wrapper collect it), held in memory while file
//! systems are frozen.

use std::io::Write;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Mutex, OnceLock};

/// Memory kept for log lines while frozen; older lines beyond it are dropped.
const MAX_HELD: usize = 1 << 20;

static HOLDING: AtomicBool = AtomicBool::new(false);
static HELD: Mutex<Vec<u8>> = Mutex::new(Vec::new());

/// Where lines go when not held: stderr, or a file (a Windows service has no stderr).
static FILE: OnceLock<Mutex<std::fs::File>> = OnceLock::new();

/// A log file starts over beyond this size.
const MAX_FILE: u64 = 10 << 20;

pub struct LogWriter;

fn emit(buf: &[u8]) -> std::io::Result<()> {
    match FILE.get() {
        Some(file) => file
            .lock()
            .unwrap_or_else(|p| p.into_inner())
            .write_all(buf),
        None => std::io::stderr().write_all(buf),
    }
}

impl Write for LogWriter {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        if HOLDING.load(Ordering::Acquire) {
            let mut held = HELD.lock().unwrap_or_else(|p| p.into_inner());
            if held.len() + buf.len() <= MAX_HELD {
                held.extend_from_slice(buf);
            }
            return Ok(buf.len());
        }
        emit(buf)?;
        Ok(buf.len())
    }

    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

/// `%ProgramData%\VMPane\agent.log`.
#[cfg(windows)]
pub fn service_log_path() -> std::path::PathBuf {
    let base = std::env::var_os("ProgramData")
        .map_or_else(|| r"C:\ProgramData".into(), std::path::PathBuf::from);
    base.join("VMPane").join("agent.log")
}

/// Starts or stops holding log output; stopping writes out what was held.
pub fn hold(on: bool) {
    HOLDING.store(on, Ordering::Release);
    if !on {
        let held = std::mem::take(&mut *HELD.lock().unwrap_or_else(|p| p.into_inner()));
        let _ = emit(&held);
    }
}

pub fn init(verbose: bool, file: Option<std::path::PathBuf>) {
    if let Some(path) = file {
        if let Some(dir) = path.parent() {
            let _ = std::fs::create_dir_all(dir);
        }
        let fresh = std::fs::metadata(&path).map_or(true, |m| m.len() > MAX_FILE);
        let opened = std::fs::OpenOptions::new()
            .create(true)
            .write(true)
            .append(!fresh)
            .truncate(fresh)
            .open(&path);
        if let Ok(opened) = opened {
            let _ = FILE.set(Mutex::new(opened));
        }
    }
    let level = if verbose {
        tracing::Level::DEBUG
    } else {
        tracing::Level::INFO
    };
    tracing_subscriber::fmt()
        .with_writer(|| LogWriter)
        .with_max_level(level)
        .with_ansi(false)
        .init();
}
