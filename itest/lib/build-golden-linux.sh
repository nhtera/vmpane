#!/usr/bin/env bash
# Builds the golden Linux bundle for integration scenarios: Ubuntu 24.04 arm64 cloud image (pinned in
# itest/images.lock) as a raw sparse 8 GiB disk, plus a cloud-init seed that, on every boot, prints
#   VMPANE-ITEST-READY boot=<boot id>          once the system is up
#   VMPANE-TICK uptime=<s> boot=<boot id>       every 2 s (proves a restored VM kept running processes)
# on the serial console (logs/serial.log). The first boot runs here, through VMPane's own helper, so
# cloud-init's one-time work is done before scenarios clone it.
# Usage: build-golden-linux.sh <bundle path>   (needs $APP and $VMPANE_ROOT; uses a throwaway support dir)
set -euo pipefail
golden=$1
source "$VMPANE_ROOT/itest/lib/common.sh"
IT_SCENARIO=golden-linux

image=$(it_image ubuntu-24.04-arm64-cloud)
work=$(mktemp -d /tmp/vp-golden.XXXXXX)
export VMPANE_SUPPORT_DIR="$work/s"
trap 'rm -rf "$work"' EXIT

rm -rf "$golden.partial" "$golden"  # an unfinished golden (no .ready) is rebuilt from scratch
mkdir -p "$(dirname "$golden")"
it_create_bundle "$golden.partial" linux \
    '.name = "linux-base" | .removable = [{id: "seed", path: "'"$golden"'/seed.iso", bus: "virtio"}]'
/opt/homebrew/bin/qemu-img convert -O raw "$image" "$golden.partial/current/disk.img"
/opt/homebrew/bin/qemu-img resize -f raw "$golden.partial/current/disk.img" 8G >/dev/null

seed=$(mktemp -d "$work/seed.XXXXXX")
cat >"$seed/meta-data" <<META
instance-id: vmpane-itest
local-hostname: vmpane-itest
META
cat >"$seed/user-data" <<'USER'
#cloud-config
write_files:
  - path: /usr/local/bin/vmpane-itest-markers
    permissions: '0755'
    content: |
      #!/bin/sh
      boot=$(cat /proc/sys/kernel/random/boot_id)
      echo "VMPANE-ITEST-READY boot=$boot"
      while true; do
        echo "VMPANE-TICK uptime=$(cut -d. -f1 /proc/uptime) boot=$boot"
        sleep 2
      done
  - path: /etc/systemd/system/vmpane-itest.service
    content: |
      [Unit]
      Description=VMPane itest markers on the serial console
      After=multi-user.target
      [Service]
      ExecStart=/usr/local/bin/vmpane-itest-markers
      StandardOutput=tty
      TTYPath=/dev/hvc0
      TTYVHangup=no
      TTYReset=no
      Restart=always
      [Install]
      WantedBy=multi-user.target
runcmd:
  # The serial getty hangs up hvc0 when it starts, cutting off the markers: no login prompt there.
  - [systemctl, mask, --now, serial-getty@hvc0.service]
  - [systemctl, daemon-reload]
  - [systemctl, enable, --now, vmpane-itest.service]
  - [systemctl, restart, vmpane-itest.service]
USER
hdiutil makehybrid -quiet -o "$golden.partial/seed.iso" "$seed" -iso -joliet -default-volume-name cidata
mv "$golden.partial" "$golden"

# First boot (cloud-init), then a clean ACPI shutdown.
pid=$(it_start_helper "$golden")
socket=$(it_socket "$golden")
it_rpc "$socket" vm.start '{"headless": true}' >/dev/null
it_wait_for 300 grep -q VMPANE-ITEST-READY "$golden/logs/serial.log" || { kill "$pid"; it_fail "first boot never got ready"; exit 1; }
it_rpc "$socket" vm.stop '{"mode": "graceful"}' >/dev/null
it_wait_for 60 bash -c "[[ \$(/usr/bin/python3 '$VMPANE_ROOT/itest/lib/rpc.py' '$socket' vm.info | jq -r .state) == stopped ]]" \
    || it_fail "golden VM did not shut down"
it_rpc "$socket" helper.shutdown >/dev/null || true
it_wait_exit "$pid" || true
rm -f "$golden/logs/serial.log"
touch "$golden/.ready"
echo "golden Linux bundle ready: $golden"
