#!/usr/bin/env bash
# Builds the golden Windows bundle from the Gate 00 S1 install (Windows 11 Pro 26H2 ARM64, local account with
# auto-logon, ramfb, no virtio drivers), until Phase 06 can install Windows unattended. Only
# the disk is imported (APFS clone); the UEFI variables (our Secure Boot template: PK, MS KEK/db, dbx) and
# the TPM are VMPane's own, made at first start like any VM VMPane creates: with no boot entry, EDK2 boots
# Windows through \EFI\BOOT\BOOTAA64.EFI. Then boots it once through the helper to the desktop and shuts
# it down. (BitLocker must be off on that install: with a new TPM Windows would ask for the recovery key
# and the desktop check fails.)
# Usage: build-golden-windows.sh <bundle path>   (needs $APP, $VMPANE_ROOT; VMPANE_WIN_SPIKE overrides the source)
set -euo pipefail
golden=$1
source "$VMPANE_ROOT/itest/lib/common.sh"
IT_SCENARIO=golden-windows

source_dir=${VMPANE_WIN_SPIKE:-$VMPANE_ROOT/spikes/s01-win-qemu-boot/assets/win-sb2}
[[ -f $source_dir/disk.raw ]] || { echo "golden-windows: missing $source_dir/disk.raw (the S1 spike install)" >&2; exit 77; }

work=$(cd "$(mktemp -d /tmp/vp-golden-win.XXXXXX)" && pwd -P)
export VMPANE_SUPPORT_DIR="$work/s"
trap 'set +e; [[ -n ${pid:-} ]] && kill -TERM "$pid" 2>/dev/null && it_wait_exit "$pid" 150; rm -rf "$work"' EXIT
rm -rf "$golden.partial" "$golden"
mkdir -p "$(dirname "$golden")"
it_create_bundle "$golden.partial" windows \
    '.name = "windows-base" | .backend = "qemu" | .cpu.count = 4 | .memory.mib = 4096 | .vz = null
     | .disks[0] |= (.bus = "nvme" | .sizeGiB = 64) | .network = [] | .audio.output = false
     | .qemu = {tpm: true, secureBoot: true, gpu: "ramfb", storageBus: "nvme", smbiosUUID: "'"$(uuidgen)"'"}
     | .windows = {}'
cp -c "$source_dir/disk.raw" "$golden.partial/current/disk.img"
chmod -R go-rwx "$golden.partial"
mv "$golden.partial" "$golden"

pid=$(it_start_helper "$golden")
socket=$(it_socket "$golden")
start=$SECONDS
it_rpc "$socket" vm.start '{"headless": true}' >/dev/null || { it_fail "vm.start failed"; exit 1; }
it_wait_windows_desktop "$socket" 180 || { it_fail "no Windows desktop within 180 s"; exit 1; }
echo "golden-windows: desktop after $((SECONDS - start)) s"
sleep 60  # let first-boot work settle before the shutdown
it_rpc "$socket" vm.stop '{"mode": "graceful"}' >/dev/null
it_wait_for 150 bash -c "[[ \$(/usr/bin/python3 '$VMPANE_ROOT/itest/lib/rpc.py' '$socket' vm.info | jq -r .state) == stopped ]]" \
    || { it_fail "golden Windows VM did not shut down within 150 s"; exit 1; }
it_rpc "$socket" helper.shutdown >/dev/null || true
it_wait_exit "$pid" 30 || true
pid=
echo "$IT_GOLDEN_WINDOWS_VERSION" >"$golden/.ready"
du -sh "$golden" | awk '{print "golden Windows bundle ready: " $1}'
