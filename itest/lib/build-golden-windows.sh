#!/usr/bin/env bash
# Builds the golden Windows bundle from the Gate 00 S1 install (Windows 11 Pro 26H2 ARM64, our Secure Boot
# EDK2, local account with auto-logon, ramfb, no virtio drivers), until Phase 06 can install Windows
# unattended. Imports the spike's disk (APFS clone), its UEFI variables (boot entries; same EDK2 commit)
# and its TPM state, which the spike kept encrypted: swtpm_ioctl (Homebrew swtpm, development only)
# exports it from a keyed swtpm and imports it into an unkeyed one. Then boots it once through VMPane's
# helper to the desktop and shuts it down.
# Usage: build-golden-windows.sh <bundle path>   (needs $APP, $VMPANE_ROOT; VMPANE_WIN_SPIKE overrides the source)
set -euo pipefail
golden=$1
source "$VMPANE_ROOT/itest/lib/common.sh"
IT_SCENARIO=golden-windows

source_dir=${VMPANE_WIN_SPIKE:-$VMPANE_ROOT/spikes/s01-win-qemu-boot/assets/win-sb2}
ioctl=/opt/homebrew/bin/swtpm_ioctl
for need in "$source_dir/disk.raw" "$source_dir/own-vars.fd" "$source_dir/tpm/tpm2-00.permall" "$source_dir/tpm.key" "$ioctl"; do
    [[ -e $need ]] || { echo "golden-windows: missing $need (the S1 spike install, or brew install swtpm)" >&2; exit 77; }
done
swtpm=$APP/Contents/Helpers/qemu/bin/swtpm

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
cp "$source_dir/own-vars.fd" "$golden.partial/current/aux/efi_vars.fd"

# TPM state: keyed swtpm → state blob → unkeyed swtpm in the bundle. The key never leaves its file.
tpm=$golden.partial/current/aux/tpm
mkdir -p "$work/old" "$tpm"
cp "$source_dir/tpm/tpm2-00.permall" "$work/old/"
"$swtpm" socket --tpm2 --tpmstate dir="$work/old" --ctrl type=unixio,path="$work/old.sock" \
    --key file="$source_dir/tpm.key",format=hex,mode=aes-256-cbc --daemon
it_wait_for 5 test -S "$work/old.sock"
"$ioctl" --unix "$work/old.sock" -i
"$ioctl" --unix "$work/old.sock" --save permanent "$work/permanent.blob"
"$ioctl" --unix "$work/old.sock" -s
"$swtpm" socket --tpm2 --tpmstate dir="$tpm" --ctrl type=unixio,path="$work/new.sock" --daemon
it_wait_for 5 test -S "$work/new.sock"
"$ioctl" --unix "$work/new.sock" --load permanent "$work/permanent.blob"
"$ioctl" --unix "$work/new.sock" -i
"$ioctl" --unix "$work/new.sock" -s
rm -f "$work/permanent.blob" "$tpm/.lock"
[[ -s $tpm/tpm2-00.permall ]] || { it_fail "TPM state import failed"; exit 1; }
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
