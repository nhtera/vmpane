//! Agent-wide state that outlives connections: identity, caps, the file system freeze, the session helper.

use std::time::Instant;

use vmpane_agent_proto::methods::{AgentInfo, cap};

use crate::freeze::Freeze;

/// What the agent tells the host about the guest.
#[derive(Debug, Clone)]
pub struct Identity {
    pub os: String,
    pub arch: String,
    pub os_version: String,
}

pub struct Agent {
    pub identity: Identity,
    pub started: Instant,
    pub freeze: Freeze,
}

impl Agent {
    pub fn new() -> Agent {
        Agent {
            identity: Identity {
                os: std::env::consts::OS.to_owned(),
                arch: std::env::consts::ARCH.to_owned(),
                os_version: crate::os::os_version(),
            },
            started: Instant::now(),
            freeze: Freeze::default(),
        }
    }

    /// Caps the daemon serves itself. Session caps (clipboard, display, reveal) come with the session helper.
    pub fn caps(&self) -> Vec<String> {
        let mut caps = vec![cap::EXEC, cap::FILE, cap::TIME, cap::POWER];
        if crate::os::HAS_NET_INFO {
            caps.extend([cap::NET, cap::PORTS]);
        }
        caps.push(cap::FREEZE);
        caps.into_iter().map(str::to_owned).collect()
    }

    pub fn has_cap(&self, name: &str) -> bool {
        self.caps().iter().any(|c| c == name)
    }

    pub fn session_connected(&self) -> bool {
        false
    }

    pub fn info(&self, proto: u32) -> AgentInfo {
        AgentInfo {
            agent_version: env!("CARGO_PKG_VERSION").to_owned(),
            proto,
            os: self.identity.os.clone(),
            arch: self.identity.arch.clone(),
            os_version: self.identity.os_version.clone(),
            caps: self.caps(),
            session: self.session_connected(),
            uptime_ms: u64::try_from(self.started.elapsed().as_millis()).unwrap_or(u64::MAX),
        }
    }
}
