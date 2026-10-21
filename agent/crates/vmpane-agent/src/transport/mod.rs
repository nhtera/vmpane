//! Transports to the host. The daemon dials; the host listens. Tried in order on every (re)connect:
//! vsock (VZ guests), virtio-serial (QEMU guests), then TCP with a token (fallbacks). `unix:` is for tests.

use std::path::PathBuf;

use tokio::io::{AsyncRead, AsyncWrite};

#[cfg(unix)]
pub(crate) mod unix;
#[cfg(any(target_os = "linux", target_os = "macos"))]
mod vsock;

mod serial;
mod tcp;

pub trait Io: AsyncRead + AsyncWrite + Unpin + Send {}
impl<T: AsyncRead + AsyncWrite + Unpin + Send> Io for T {}

/// A connected byte stream to the host.
pub type BoxIo = Box<dyn Io>;

/// Whether this agent's connection to the host needs `transport.ack` (cap `ack`): a macOS guest's vsock stalls
/// for good once about 240 KiB are in flight, so it keeps less than that unacknowledged.
pub const NEEDS_ACKS: bool = cfg!(target_os = "macos");

/// The host has received `bytes` on the current connection (`transport.ack`).
pub fn host_acked(bytes: u64) {
    #[cfg(target_os = "macos")]
    vsock::host_acked(bytes);
    #[cfg(not(target_os = "macos"))]
    let _ = bytes;
}

/// Host CID of the vsock device.
pub const HOST_CID: u32 = 2;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Endpoint {
    Vsock {
        cid: u32,
        port: u32,
    },
    Serial(PathBuf),
    /// TCP needs the per-VM token from `token_file` in `hello`.
    Tcp {
        addr: String,
        token_file: PathBuf,
    },
    Unix(PathBuf),
    /// A named pipe (the Windows session helper's link to the service).
    #[cfg(windows)]
    Pipe(String),
}

impl Endpoint {
    /// Parses `vsock[:cid:port]`, `serial[:path]`, `tcp:host:port`, `unix:path`.
    pub fn parse(spec: &str, token_file: &std::path::Path) -> Option<Endpoint> {
        let (kind, rest) = spec.split_once(':').unwrap_or((spec, ""));
        match kind {
            "vsock" if rest.is_empty() => Some(Endpoint::Vsock {
                cid: HOST_CID,
                port: vmpane_agent_proto::VSOCK_PORT,
            }),
            "vsock" => {
                let (cid, port) = rest.split_once(':')?;
                Some(Endpoint::Vsock {
                    cid: cid.parse().ok()?,
                    port: port.parse().ok()?,
                })
            }
            "serial" if rest.is_empty() => Some(Endpoint::Serial(serial::default_path())),
            "serial" => Some(Endpoint::Serial(PathBuf::from(rest))),
            "tcp" if !rest.is_empty() => Some(Endpoint::Tcp {
                addr: rest.to_owned(),
                token_file: token_file.to_owned(),
            }),
            "unix" if !rest.is_empty() => Some(Endpoint::Unix(PathBuf::from(rest))),
            _ => None,
        }
    }

    /// The order `auto` tries on this OS.
    pub fn auto(token_file: &std::path::Path) -> Vec<Endpoint> {
        let vsock = Endpoint::Vsock {
            cid: HOST_CID,
            port: vmpane_agent_proto::VSOCK_PORT,
        };
        let serial = Endpoint::Serial(serial::default_path());
        let qemu_tcp = Endpoint::Tcp {
            addr: vmpane_agent_proto::QEMU_TCP_ADDR.to_owned(),
            token_file: token_file.to_owned(),
        };
        if cfg!(target_os = "linux") {
            vec![vsock, serial, qemu_tcp]
        } else if cfg!(target_os = "macos") {
            let mut list = vec![vsock];
            // VZ NAT: the host is the default gateway.
            if let Some(gateway) = crate::os::default_gateway() {
                list.push(Endpoint::Tcp {
                    addr: format!("{gateway}:{}", vmpane_agent_proto::VSOCK_PORT),
                    token_file: token_file.to_owned(),
                });
            }
            list
        } else {
            vec![serial, qemu_tcp]
        }
    }

    /// Where a session helper reaches its daemon: a Unix socket, or on Windows the named pipe it was given.
    pub fn session(path: &std::path::Path) -> Endpoint {
        #[cfg(windows)]
        {
            Endpoint::Pipe(path.to_string_lossy().into_owned())
        }
        #[cfg(not(windows))]
        {
            Endpoint::Unix(path.to_owned())
        }
    }

    pub fn needs_token(&self) -> bool {
        matches!(self, Endpoint::Tcp { .. })
    }

    pub async fn connect(&self) -> std::io::Result<BoxIo> {
        match self {
            #[cfg(any(target_os = "linux", target_os = "macos"))]
            Endpoint::Vsock { cid, port } => vsock::connect(*cid, *port).await,
            #[cfg(not(any(target_os = "linux", target_os = "macos")))]
            Endpoint::Vsock { .. } => Err(std::io::ErrorKind::Unsupported.into()),
            Endpoint::Serial(path) => serial::open(path).await,
            Endpoint::Tcp { addr, .. } => tcp::connect(addr).await,
            #[cfg(unix)]
            Endpoint::Unix(path) => unix::connect(path).await,
            #[cfg(not(unix))]
            Endpoint::Unix(_) => Err(std::io::ErrorKind::Unsupported.into()),
            #[cfg(windows)]
            Endpoint::Pipe(name) => Ok(Box::new(
                tokio::net::windows::named_pipe::ClientOptions::new().open(name)?,
            )),
        }
    }
}

impl std::fmt::Display for Endpoint {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Endpoint::Vsock { cid, port } => write!(f, "vsock:{cid}:{port}"),
            Endpoint::Serial(path) => write!(f, "serial:{}", path.display()),
            Endpoint::Tcp { addr, .. } => write!(f, "tcp:{addr}"),
            Endpoint::Unix(path) => write!(f, "unix:{}", path.display()),
            #[cfg(windows)]
            Endpoint::Pipe(name) => write!(f, "pipe:{name}"),
        }
    }
}

#[cfg(test)]
mod tests {
    use std::path::Path;

    use super::*;

    #[test]
    fn parses_specs() {
        let token = Path::new("/t");
        assert_eq!(
            Endpoint::parse("vsock", token),
            Some(Endpoint::Vsock { cid: 2, port: 6271 })
        );
        assert_eq!(
            Endpoint::parse("vsock:3:99", token),
            Some(Endpoint::Vsock { cid: 3, port: 99 })
        );
        assert_eq!(
            Endpoint::parse("unix:/s", token),
            Some(Endpoint::Unix("/s".into()))
        );
        assert_eq!(
            Endpoint::parse("tcp:10.0.2.200:6271", token),
            Some(Endpoint::Tcp {
                addr: "10.0.2.200:6271".into(),
                token_file: "/t".into()
            })
        );
        assert_eq!(Endpoint::parse("tcp", token), None);
        assert_eq!(Endpoint::parse("carrier-pigeon", token), None);
    }
}
