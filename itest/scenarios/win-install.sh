# Unattended Windows 11 install on the QEMU backend, from a Microsoft ISO to a signed-in desktop with no input:
#   1. the wizard's step (WindowsInstall.prepare under the helper's lock, VMPANE_TEST_WIN_INSTALL) on a blank
#      VM with the guest-tools ISO (guest-tools/build-iso.sh), for a Mac set to a language the ISO lacks (vi-VN):
#      the answers must use one the ISO has, or Setup stops at its language page;
#   2. the helper drives it: first boot, Setup (the ISO ejected at its first reboot), first sign-in, guest tools,
#      finalize (no install media, virtio display, NIC back), and the VM starts again (target ≤ 40 min);
#   3. the desktop comes up, and the password is nowhere in the bundle (config, logs, install/) or the helper log.
# ISO: $VMPANE_WINDOWS_ISO, else ~/Downloads/Win*arm64*.iso; none (or < 25 GiB free: prepare needs 20) → skipped.
# Inside the guest (drivers, DNS, no Winlogon DefaultPassword / Panther answers) needs the agent: Phase 07.
source "$VMPANE_ROOT/itest/lib/common.sh"
IT_SCENARIO=win-install

scenario_run() {
    local out iso tools work bundle request password pid socket start state
    iso=$(it_windows_iso) || { echo "win-install: no Windows 11 Arm64 ISO (set VMPANE_WINDOWS_ISO)"; return 77; }
    (($(df -g "$HOME" | awk 'NR == 2 {print $4}') >= 25)) || { echo "win-install: needs 25 GiB free"; return 77; }
    tools=$("$VMPANE_ROOT/guest-tools/build-iso.sh" | tail -1) || it_fail "cannot build the guest-tools ISO" || return 1

    work=$(cd "$(mktemp -d /tmp/vp-wi.XXXXXX)" && pwd -P)
    export VMPANE_SUPPORT_DIR="$work/s"
    mkdir -p "$VMPANE_SUPPORT_DIR/VMs"
    bundle="$VMPANE_SUPPORT_DIR/VMs/W.vmpane"
    trap 'set +e; unset VMPANE_TEST_WIN_INSTALL; [[ -n ${pid:-} ]] && kill -TERM "$pid" 2>/dev/null && it_wait_exit "$pid" 150; rm -rf "$work"; true' RETURN

    # 1. The request holds the password: 0600, and the helper deletes it once read.
    password="It-$(uuidgen | cut -c1-12)"
    request="$work/request.json"
    it_windows_install_bundle "$bundle" "$iso" "$tools" "$request" "$password" vi-VN
    export VMPANE_TEST_WIN_INSTALL=$request
    pid=$(it_start_helper "$bundle") || return 1
    unset VMPANE_TEST_WIN_INSTALL
    [[ ! -e $request ]] || it_fail "the helper left the request (with the password) behind" || return 1
    [[ $(jq -r .install.media "$bundle/config.json") == windows ]] || it_fail "the install was not prepared" || return 1
    socket=$(it_socket "$bundle")

    # 2. The install, watched through install/install.json.
    start=$SECONDS
    out=$(it_rpc "$socket" vm.start '{"headless": true}') || it_fail "vm.start failed: $out" || return 1
    it_wait_install "$bundle" 80 || return 1
    echo "win-install: installed in $(((SECONDS - start) / 60)) min (target ≤ 40)"

    # 3. Finalized and running again, with the desktop up and no password left.
    it_wait_for 120 bash -c "[[ \$(/usr/bin/python3 '$VMPANE_ROOT/itest/lib/rpc.py' '$socket' vm.info | jq -r .state) == running ]]" \
        || it_fail "the VM did not start again after finalize" || return 1
    jq -e '.install == null and .removable == [] and .qemu.gpu == "virtio" and (.network | length) > 0' "$bundle/config.json" >/dev/null \
        || it_fail "finalize left the config as $(jq -c '{install, removable, qemu, network}' "$bundle/config.json")" || return 1
    it_wait_windows_desktop "$socket" 300 || it_fail "no desktop within 5 min of finalize" || return 1
    [[ ! -e $bundle/install/unattend.iso ]] || it_fail "unattend.iso is still in the bundle" || return 1
    if grep -rlF --exclude=disk.img -- "$password" "$bundle" "$VMPANE_SUPPORT_DIR"/helper-*.log 2>/dev/null; then
        it_fail "the password is in the files above"
        return 1
    fi
    state=$(it_rpc "$socket" vm.info | jq -r .state)
    echo "win-install: desktop up, VM $state, no password in the bundle or the logs"
    it_rpc "$socket" vm.stop '{"mode": "graceful"}' >/dev/null
    it_wait_for 150 bash -c "[[ \$(/usr/bin/python3 '$VMPANE_ROOT/itest/lib/rpc.py' '$socket' vm.info | jq -r .state) == stopped ]]" || true
    it_rpc "$socket" helper.shutdown >/dev/null
    it_wait_exit "$pid" 30 || true
    pid=
    return 0
}
