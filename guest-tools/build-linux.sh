#!/usr/bin/env bash
# Stages the Linux guest tools: the static aarch64 musl agent, its installer and systemd units, and SHA256SUMS,
# in build/guest-tools/linux/ (the app embeds it as Contents/Resources/GuestTools/linux; VZ Linux guests see it
# read-only as the virtiofs tag `vmpane-tools`). Prints the directory.
# Usage: guest-tools/build-linux.sh
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
out="$root/build/guest-tools/linux"

(cd "$root/agent" && cargo build --release --locked --quiet --target aarch64-unknown-linux-musl -p vmpane-agent)
rm -rf "$out.partial"
mkdir -p "$out.partial"
install -m 0755 "$root/agent/target/aarch64-unknown-linux-musl/release/vmpane-agent" "$out.partial/vmpane-agent"
install -m 0755 "$root/agent/installer/linux/install.sh" "$out.partial/install.sh"
install -m 0644 "$root/agent/installer/linux/vmpane-agent.service" "$out.partial/vmpane-agent.service"
install -m 0644 "$root/agent/installer/linux/vmpane-session.service" "$out.partial/vmpane-session.service"
install -m 0644 "$root/agent/installer/linux/vmpane-session-env.desktop" "$out.partial/vmpane-session-env.desktop"
(cd "$out.partial" && shasum -a 256 vmpane-agent install.sh vmpane-agent.service vmpane-session.service \
    vmpane-session-env.desktop >SHA256SUMS)
rm -rf "$out"
mv "$out.partial" "$out"
echo "$out"
