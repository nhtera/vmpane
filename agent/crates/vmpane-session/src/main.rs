//! VMPane session helper: runs in the logged-in user's session for clipboard and display work.

fn main() {
    println!(
        "vmpane-session {} (protocol {})",
        env!("CARGO_PKG_VERSION"),
        vmpane_agent_proto::PROTOCOL_VERSION
    );
}
