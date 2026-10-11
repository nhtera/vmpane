//! Logging to stderr (journald, launchd and the service wrapper collect it), held in memory while file
//! systems are frozen.

use std::io::Write;
use std::sync::Mutex;
use std::sync::atomic::{AtomicBool, Ordering};

/// Memory kept for log lines while frozen; older lines beyond it are dropped.
const MAX_HELD: usize = 1 << 20;

static HOLDING: AtomicBool = AtomicBool::new(false);
static HELD: Mutex<Vec<u8>> = Mutex::new(Vec::new());

pub struct LogWriter;

impl Write for LogWriter {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        if HOLDING.load(Ordering::Acquire) {
            let mut held = HELD.lock().unwrap_or_else(|p| p.into_inner());
            if held.len() + buf.len() <= MAX_HELD {
                held.extend_from_slice(buf);
            }
            return Ok(buf.len());
        }
        std::io::stderr().write(buf)
    }

    fn flush(&mut self) -> std::io::Result<()> {
        std::io::stderr().flush()
    }
}

/// Starts or stops holding log output; stopping writes out what was held.
pub fn hold(on: bool) {
    HOLDING.store(on, Ordering::Release);
    if !on {
        let held = std::mem::take(&mut *HELD.lock().unwrap_or_else(|p| p.into_inner()));
        let _ = std::io::stderr().write_all(&held);
    }
}

pub fn init(verbose: bool) {
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
