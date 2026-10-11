//! Wire format shared by the VMPane guest agent and the host: frames ([`frame`]), JSON-RPC 2.0 messages
//! ([`jsonrpc`]), method types ([`methods`]) and limits ([`limits`]). No async runtime: the optional
//! `tokio-codec` feature adds tokio-util's Decoder/Encoder for [`frame::FrameDecoder`].
//!
//! The host treats every guest byte as untrusted; both sides enforce the same limits, and the shared vectors
//! in `proto/vectors` keep the host's Swift codec in step with this one.
#![deny(unsafe_code)]

pub mod error;
pub mod frame;
pub mod jsonrpc;
pub mod limits;
pub mod methods;
pub mod schema;

/// Newest agent protocol version this build speaks.
pub const PROTO: u32 = 1;
/// Oldest version this build speaks: the compatibility floor, 1 for all of v1.x.
pub const MIN_PROTO: u32 = 1;

/// Version of the daemon ⇄ session helper protocol (inside the guest). A mismatch makes the daemon restart the
/// session helper from the installed binary.
pub const IPC_VERSION: u32 = 1;

/// vsock port the host listens on (VZ guests dial CID 2).
pub const VSOCK_PORT: u32 = 6271;
/// virtio-serial port name (QEMU guests).
pub const SERIAL_PORT_NAME: &str = "app.vmpane.agent.0";
/// TCP fallback inside QEMU's user network (slirp `guestfwd` to a host socket).
pub const QEMU_TCP_ADDR: &str = "10.0.2.200:6271";

/// The version two peers use: the highest one both speak, or None when their ranges do not overlap (or a
/// range is empty).
pub fn negotiate(ours: (u32, u32), theirs: (u32, u32)) -> Option<u32> {
    let (low, high) = (ours.0.max(theirs.0), ours.1.min(theirs.1));
    (ours.0 <= ours.1 && theirs.0 <= theirs.1 && low <= high).then_some(high)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn negotiates_the_highest_common_version() {
        assert_eq!(negotiate((1, 3), (2, 5)), Some(3));
        assert_eq!(negotiate((1, 1), (1, 1)), Some(1));
        assert_eq!(negotiate((2, 3), (1, 1)), None);
        assert_eq!(negotiate((1, 3), (3, 2)), None);
    }
}
