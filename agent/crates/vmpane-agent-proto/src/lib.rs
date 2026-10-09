//! Wire format shared by the VMPane guest agent and the host.
//!
//! Frames and messages are added with the agent protocol; this crate only fixes the version now.

/// Protocol version the agent speaks. The host refuses agents with a different major version.
pub const PROTOCOL_VERSION: u32 = 1;

/// Returns true when a peer speaking `peer` can talk to this build.
pub fn is_compatible(peer: u32) -> bool {
    peer == PROTOCOL_VERSION
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn same_version_is_compatible() {
        assert!(is_compatible(PROTOCOL_VERSION));
        assert!(!is_compatible(PROTOCOL_VERSION + 1));
    }
}
