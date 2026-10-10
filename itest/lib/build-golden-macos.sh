#!/usr/bin/env bash
# Builds the golden macOS bundle: installs macOS from the pinned IPSW (itest/images.lock) through
# VMPane's own helper (VZMacOSInstaller), boots the installed system once, then shuts it down.
# The guest stays at Setup Assistant. Usage: build-golden-macos.sh <bundle path>   (needs $APP, $VMPANE_ROOT)
set -euo pipefail
golden=$1
source "$VMPANE_ROOT/itest/lib/common.sh"
IT_SCENARIO=golden-macos

# Reuse the app's IPSW cache when it already holds the pinned image.
read -r url sha < <(awk '$1 == "macos-15.6.1-ipsw" {print $2, $3}' "$VMPANE_ROOT/itest/images.lock")
ipsw="$HOME/Library/Caches/app.vmpane.mac/IPSW/$(basename "$url")"
if [[ ! -f $ipsw ]]; then ipsw=$(it_image macos-15.6.1-ipsw); fi
[[ $(shasum -a 256 "$ipsw" | awk '{print $1}') == "$sha" ]] || { it_fail "IPSW sha256 mismatch"; exit 1; }

work=$(mktemp -d /tmp/vp-golden-mac.XXXXXX)
export VMPANE_SUPPORT_DIR="$work/s"
trap 'set +e; [[ -n ${pid:-} ]] && kill -TERM "$pid" 2>/dev/null && it_wait_exit "$pid" 30; rm -rf "$work"' EXIT
rm -rf "$golden.partial" "$golden"
mkdir -p "$(dirname "$golden")"
it_create_bundle "$golden.partial" macos \
    '.name = "macos-base" | .cpu.count = 4 | .memory.mib = 8192 | .disks[0].sizeGiB = 64
     | .display = {widthPx: 1920, heightPx: 1200, ppi: 144, autoResize: true, scaling: "retina"}
     | del(.vz.rosetta) | .vz = {rosetta: false, nestedVirtualization: false}
     | .install = {restoreImage: "'"$ipsw"'"}'
truncate -s 64g "$golden.partial/current/disk.img"
mv "$golden.partial" "$golden"

pid=$(it_start_helper "$golden")
socket=$(it_socket "$golden")
start=$SECONDS
if ! result=$(it_rpc "$socket" vm.start '{"headless": true}'); then
    it_fail "install/start failed: $result"
    exit 1
fi
echo "macOS installed and started in $((SECONDS - start)) s"
[[ $(jq -r '.install // empty' "$golden/config.json") == "" ]] || it_fail "install source not cleared"
sleep 90  # first boot of the installed system (to Setup Assistant)
# Setup Assistant ignores the ACPI power button, and has nothing to save: power off.
it_rpc "$socket" vm.stop '{"mode": "force"}' >/dev/null
it_wait_for 30 bash -c "[[ \$(/usr/bin/python3 '$VMPANE_ROOT/itest/lib/rpc.py' '$socket' vm.info | jq -r .state) == stopped ]]" \
    || { it_fail "golden macOS VM did not stop"; exit 1; }
it_rpc "$socket" helper.shutdown >/dev/null || true
it_wait_exit "$pid" || true
pid=
touch "$golden/.ready"
du -sh "$golden" | awk '{print "golden macOS bundle ready: " $1}'
