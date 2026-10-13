#!/usr/bin/env bash
# Builds the golden Windows bundle the Windows scenarios clone: VMPane's own unattended install (as win-install)
# from the ISO it_windows_iso finds, with the guest tools (virtio drivers, virtio display, network), then shut
# down. A local account with a throwaway password and no auto sign-in: a boot ends at the lock screen, which the
# desktop check (it_wait_windows_desktop) counts.
# Usage: build-golden-windows.sh <bundle path>   (needs $APP, $VMPANE_ROOT; exit 77 without an ISO or 25 GiB free)
set -euo pipefail
golden=$1
source "$VMPANE_ROOT/itest/lib/common.sh"
IT_SCENARIO=golden-windows

iso=$(it_windows_iso) || { echo "golden-windows: no Windows 11 Arm64 ISO (set VMPANE_WINDOWS_ISO)" >&2; exit 77; }
work_iso="$VMPANE_ROOT/build/guest-tools/itest-golden-tools.iso"
rm -rf "$golden.partial" "$golden"  # an outdated golden: its space counts towards the check below
(($(df -g "$HOME" | awk 'NR == 2 {print $4}') >= 25)) || { echo "golden-windows: needs 25 GiB free" >&2; exit 77; }
# The agent MSI, when downloaded (guest-tools/fetch-agent-msi.sh), goes onto the tools disc: the install adds it.
with_agent=
if compgen -G "$IT_WINDOWS_EXTRA/*.msi" >/dev/null; then
    export VMPANE_GUEST_TOOLS_EXTRA=$IT_WINDOWS_EXTRA
    with_agent=1
fi
tools=$("$VMPANE_ROOT/guest-tools/build-iso.sh" "$work_iso" | tail -1)

work=$(cd "$(mktemp -d /tmp/vp-golden-win.XXXXXX)" && pwd -P)
export VMPANE_SUPPORT_DIR="$work/s"
trap 'set +e; unset VMPANE_TEST_WIN_INSTALL; [[ -n ${pid:-} ]] && kill -TERM "$pid" 2>/dev/null && it_wait_exit "$pid" 150; rm -rf "$work" "$golden.partial"' EXIT
mkdir -p "$(dirname "$golden")"
it_windows_install_bundle "$golden.partial" "$iso" "$tools" "$work/request.json" "Gw-$(uuidgen | cut -c1-12)"
export VMPANE_TEST_WIN_INSTALL=$work/request.json
pid=$(it_start_helper "$golden.partial")
unset VMPANE_TEST_WIN_INSTALL
socket=$(it_socket "$golden.partial")

start=$SECONDS
out=$(it_rpc "$socket" vm.start '{"headless": true}') || { it_fail "vm.start failed: $out"; exit 1; }
it_wait_install "$golden.partial" 80 || exit 1
it_wait_for 120 bash -c "[[ \$(/usr/bin/python3 '$VMPANE_ROOT/itest/lib/rpc.py' '$socket' vm.info | jq -r .state) == running ]]" \
    || { it_fail "the VM did not start again after finalize"; exit 1; }
it_wait_windows_desktop "$socket" 300 || { it_fail "no Windows screen within 5 min of finalize"; exit 1; }
echo "golden-windows: installed and up after $(((SECONDS - start) / 60)) min"
sleep 60  # let first-boot work settle before the shutdown
it_rpc "$socket" vm.stop '{"mode": "graceful"}' >/dev/null
it_wait_for 150 bash -c "[[ \$(/usr/bin/python3 '$VMPANE_ROOT/itest/lib/rpc.py' '$socket' vm.info | jq -r .state) == stopped ]]" \
    || { it_fail "golden Windows VM did not shut down within 150 s"; exit 1; }
it_rpc "$socket" helper.shutdown >/dev/null || true
it_wait_exit "$pid" 30 || true
pid=
rm -rf "$golden.partial/install"  # only install.json (done) is left there
chmod -R go-rwx "$golden.partial"
mv "$golden.partial" "$golden"
[[ -n $with_agent ]] && it_windows_extra_sum >"$golden/.agent"
echo "$IT_GOLDEN_WINDOWS_VERSION" >"$golden/.ready"
du -sh "$golden" | awk '{print "golden Windows bundle ready: " $1}'
