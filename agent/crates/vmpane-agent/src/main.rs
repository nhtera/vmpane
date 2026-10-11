//! VMPane guest agent: runs as a system service in the guest and talks to the host over vsock.

fn main() {
    println!(
        "vmpane-agent {} (protocol {})",
        env!("CARGO_PKG_VERSION"),
        vmpane_agent_proto::PROTO
    );
}
