#!/usr/bin/env bash
# Builds the golden Linux bundle for integration scenarios: Ubuntu 24.04 arm64 cloud image (pinned in
# itest/images.lock) as a raw sparse 8 GiB disk, plus a cloud-init seed that, on every boot, prints
#   VMPANE-ITEST-READY boot=<boot id>          once the system is up
#   VMPANE-TICK uptime=<s> boot=<boot id>       every 2 s (proves a restored VM kept running processes)
#   VMPANE-TYPED <line>                         for each line typed on the graphical console (tty1)
#   VMPANE-PROBE kvm=<yes|no> rosetta=<yes|no> share=<files> fresh=<files>   after READY, and when
#                                               VMPANE-PROBE is typed (share: a mount kept since boot;
#                                               fresh: a new mount; files of the vmpane-shares tag)
#   VMPANE-POINTER-DEVICE <path> max=<x>,<y>     each absolute pointing device, at boot
#   VMPANE-POINTER button=<n> down=<0|1> x=<abs> y=<abs>   each mouse button event, with the position
# Typing VMPANE-REBOOT or VMPANE-POWEROFF on tty1 reboots or powers off the guest (a guest-initiated stop).
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
      /usr/local/bin/vmpane-itest-probe
      while true; do
        echo "VMPANE-TICK uptime=$(cut -d. -f1 /proc/uptime) boot=$boot"
        sleep 2
      done
  - path: /usr/local/bin/vmpane-itest-probe
    permissions: '0755'
    content: |
      #!/bin/sh
      # Device checks for scenarios: nested virtualization, Rosetta, VMPane shares (virtiofs).
      files() { (cd "$1" && find . -mindepth 1 -maxdepth 2 | sort | tr '\n' ',') 2>/dev/null; }
      mkdir -p /mnt/vmpane /mnt/vmpane-fresh /mnt/rosetta
      kvm=no; [ -e /dev/kvm ] && kvm=yes
      rosetta=no
      if mountpoint -q /mnt/rosetta || mount -t virtiofs rosetta /mnt/rosetta 2>/dev/null; then
        [ -x /mnt/rosetta/rosetta ] && rosetta=yes
      fi
      share=none
      if mountpoint -q /mnt/vmpane || mount -t virtiofs vmpane-shares /mnt/vmpane 2>/dev/null; then share=$(files /mnt/vmpane); fi
      fresh=none
      if mount -t virtiofs vmpane-shares /mnt/vmpane-fresh 2>/dev/null; then fresh=$(files /mnt/vmpane-fresh); umount /mnt/vmpane-fresh; fi
      echo "VMPANE-PROBE kvm=$kvm rosetta=$rosetta share=$share fresh=$fresh" > /dev/hvc0
  - path: /usr/local/bin/vmpane-itest-pointer
    permissions: '0755'
    content: |
      #!/usr/bin/python3
      # Reports absolute pointer button events (evdev) with the pointer position on the serial console.
      import fcntl, glob, os, select, struct
      EV_KEY, EV_ABS = 1, 3
      def abs_max(fd, axis):
          info = bytearray(24)  # struct input_absinfo; EVIOCGABS(axis)
          fcntl.ioctl(fd, 0x80184540 + axis, info)
          return struct.unpack("6i", info)[2]
      out = open("/dev/hvc0", "w", buffering=1)
      devices = {}
      for path in sorted(glob.glob("/dev/input/event*")):
          fd = os.open(path, os.O_RDONLY)
          try:
              if abs_max(fd, 0) > 0:
                  devices[fd] = path
                  out.write(f"VMPANE-POINTER-DEVICE {path} max={abs_max(fd, 0)},{abs_max(fd, 1)}\n")
                  continue
          except OSError:
              pass
          os.close(fd)
      x = y = 0
      while devices:
          for fd in select.select(list(devices), [], [])[0]:
              data = os.read(fd, 24 * 64)
              for i in range(0, len(data) - 23, 24):
                  _, _, kind, code, value = struct.unpack("qqHHi", data[i:i + 24])
                  if kind == EV_ABS and code == 0: x = value
                  elif kind == EV_ABS and code == 1: y = value
                  elif kind == EV_KEY and 0x110 <= code <= 0x112:
                      out.write(f"VMPANE-POINTER button={code - 0x110} down={value} x={x} y={y}\n")
  - path: /etc/systemd/system/vmpane-itest-pointer.service
    content: |
      [Unit]
      Description=VMPane itest: report pointer events on the serial console
      After=multi-user.target
      [Service]
      ExecStart=/usr/local/bin/vmpane-itest-pointer
      Restart=always
      [Install]
      WantedBy=multi-user.target
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
  - path: /usr/local/bin/vmpane-itest-typed
    permissions: '0755'
    content: |
      #!/bin/sh
      # Lines typed on the graphical console (tty1) are echoed to the serial log, so tests can check
      # synthesized keyboard input. Raw reads, so every printable character arrives as typed.
      while IFS= read -r line; do
        echo "VMPANE-TYPED $line" > /dev/hvc0
        case "$line" in
          VMPANE-REBOOT) systemctl reboot ;;
          VMPANE-POWEROFF) systemctl poweroff ;;
          VMPANE-PROBE) /usr/local/bin/vmpane-itest-probe ;;
        esac
      done
  - path: /etc/systemd/system/vmpane-itest-typed.service
    content: |
      [Unit]
      Description=VMPane itest: echo tty1 input to the serial console
      After=multi-user.target
      Conflicts=getty@tty1.service
      [Service]
      ExecStart=/usr/local/bin/vmpane-itest-typed
      StandardInput=tty
      StandardOutput=tty
      TTYPath=/dev/tty1
      TTYReset=yes
      TTYVHangup=yes
      Restart=always
      [Install]
      WantedBy=multi-user.target
runcmd:
  # The serial getty hangs up hvc0 when it starts, cutting off the markers: no login prompt there.
  - [systemctl, mask, --now, serial-getty@hvc0.service]
  - [systemctl, daemon-reload]
  - [systemctl, enable, --now, vmpane-itest.service]
  - [systemctl, restart, vmpane-itest.service]
  - [systemctl, mask, --now, getty@tty1.service]
  - [systemctl, enable, --now, vmpane-itest-typed.service]
  - [systemctl, enable, --now, vmpane-itest-pointer.service]
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
echo "$IT_GOLDEN_LINUX_VERSION" >"$golden/.ready"
echo "golden Linux bundle ready: $golden"
