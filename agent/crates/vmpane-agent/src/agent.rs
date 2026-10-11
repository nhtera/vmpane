//! Agent-wide state that outlives connections: identity, caps, the file system freeze, the session helper.

use std::sync::Arc;
use std::time::Instant;

use vmpane_agent_proto::methods::{AgentInfo, cap};

use crate::freeze::Freeze;
use crate::session_link::SessionHub;

/// The daemon (root / LocalSystem, talks to the host) or a user-session helper (talks to the daemon).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Role {
    Daemon,
    Session,
}

/// What the agent tells the host about the guest.
#[derive(Debug, Clone)]
pub struct Identity {
    pub os: String,
    pub arch: String,
    pub os_version: String,
}

pub struct Agent {
    pub role: Role,
    pub identity: Identity,
    /// The version in `hello` (a debug build's helper can pretend another, to test the mismatch path).
    pub version: String,
    pub started: Instant,
    pub freeze: Freeze,
    /// The connected user-session helper (daemon only).
    pub session: Arc<SessionHub>,
}

impl Agent {
    pub fn new(role: Role) -> Agent {
        let mut version = env!("CARGO_PKG_VERSION").to_owned();
        if cfg!(debug_assertions)
            && let Ok(pretend) = std::env::var("VMPANE_TEST_AGENT_VERSION")
        {
            version = pretend;
        }
        Agent {
            role,
            version,
            session: Arc::default(),
            identity: Identity {
                os: std::env::consts::OS.to_owned(),
                arch: std::env::consts::ARCH.to_owned(),
                os_version: crate::os::os_version(),
            },
            started: Instant::now(),
            freeze: Freeze::default(),
        }
    }

    /// What this build can do. Session caps (reveal) are advertised by the daemon too: they work while a
    /// user-session helper is connected (`session` in `hello` / `agent.info`) and answer `noSession` otherwise.
    pub fn caps(&self) -> Vec<String> {
        let caps: Vec<&str> = match self.role {
            Role::Session => vec![cap::EXEC, cap::REVEAL],
            Role::Daemon => {
                let mut caps = vec![cap::EXEC, cap::FILE, cap::TIME, cap::POWER];
                if crate::os::HAS_NET_INFO {
                    caps.extend([cap::NET, cap::PORTS]);
                }
                caps.extend([cap::FREEZE, cap::REVEAL]);
                caps
            }
        };
        caps.into_iter().map(str::to_owned).collect()
    }

    pub fn has_cap(&self, name: &str) -> bool {
        self.caps().iter().any(|c| c == name)
    }

    pub fn session_connected(&self) -> bool {
        self.role == Role::Daemon && self.session.connected()
    }

    pub fn info(&self, proto: u32) -> AgentInfo {
        AgentInfo {
            agent_version: self.version.clone(),
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
