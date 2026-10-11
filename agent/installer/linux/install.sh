#!/bin/sh
# Installs or updates the VMPane guest agent from this directory (the read-only `vmpane-tools` share):
#   sudo mount -t virtiofs vmpane-tools /mnt/vmpane-tools && sudo /mnt/vmpane-tools/install.sh
# A static binary (no distro packages), checked against SHA256SUMS: the daemon as a system unit, and the same
# binary as `vmpane-agent session` in every user's systemd session (runs commands as that user).
# `install.sh --uninstall` removes them again.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
bin=/usr/local/bin/vmpane-agent
unit=/etc/systemd/system/vmpane-agent.service
user_unit=/etc/systemd/user/vmpane-session.service

if [ "$(id -u)" -ne 0 ]; then
    echo "install.sh: run as root (sudo $0)" >&2
    exit 1
fi

if [ "${1:-}" = "--uninstall" ]; then
    systemctl disable --now vmpane-agent.service 2>/dev/null || true
    systemctl --global disable vmpane-session.service 2>/dev/null || true
    rm -f "$bin" "$unit" "$user_unit"
    systemctl daemon-reload
    echo "VMPane agent removed"
    exit 0
fi

arch=$(uname -m)
if [ "$arch" != aarch64 ]; then
    echo "install.sh: this agent is for aarch64 guests, not $arch" >&2
    exit 1
fi
if ! (cd "$here" && sha256sum -c --quiet SHA256SUMS); then
    echo "install.sh: the files do not match SHA256SUMS" >&2
    exit 1
fi

# Copy beside the target, then rename: a running agent keeps its old binary until the restart.
install -m 0755 "$here/vmpane-agent" "$bin.new"
mv -f "$bin.new" "$bin"
install -m 0644 "$here/vmpane-agent.service" "$unit"
install -d -m 0755 "$(dirname "$user_unit")"
install -m 0644 "$here/vmpane-session.service" "$user_unit"
systemctl daemon-reload
# Starts with each user's next login; running helpers of an older version are refused and restart themselves.
systemctl --global enable vmpane-session.service >/dev/null 2>&1
systemctl enable vmpane-agent.service >/dev/null 2>&1
# Last: run by the agent itself (an update through exec), the restart ends this script.
systemctl restart vmpane-agent.service
echo "VMPane agent installed: $("$bin" --version)"
