# An unattended Windows install survives losing its helper, and cancelling it leaves no password behind:
#   1. as win-install, until Setup's first reboot has ejected the Windows ISO;
#   2. the helper is killed (SIGKILL); the next helper reaps QEMU (Windows sees a power cut) and, at vm.start,
#      resumes in setupRunning: same attempt (no key presses, which only a first boot gets), the ISO out of the
#      config (it cannot boot again and wipe the disk);
#   3. vm.install.cancel: the VM stops, the unattend image is gone, the config has no install left.
# Whether Windows Setup itself recovers from the power cut is Windows' business, not checked here.
# Skips like win-install (no ISO, < 40 GiB free).
source "$VMPANE_ROOT/itest/lib/common.sh"
IT_SCENARIO=win-install-resume

scenario_run() {
    local iso tools work bundle request pid socket start attempts
    iso=$(it_windows_iso) || { echo "win-install-resume: no Windows 11 Arm64 ISO (set VMPANE_WINDOWS_ISO)"; return 77; }
    (($(df -g "$HOME" | awk 'NR == 2 {print $4}') >= 40)) || { echo "win-install-resume: needs 40 GiB free"; return 77; }
    tools=$("$VMPANE_ROOT/guest-tools/build-iso.sh" | tail -1) || it_fail "cannot build the guest-tools ISO" || return 1

    work=$(cd "$(mktemp -d /tmp/vp-wr.XXXXXX)" && pwd -P)
    export VMPANE_SUPPORT_DIR="$work/s"
    mkdir -p "$VMPANE_SUPPORT_DIR/VMs"
    bundle="$VMPANE_SUPPORT_DIR/VMs/W.vmpane"
    trap 'set +e; unset VMPANE_TEST_WIN_INSTALL; [[ -n ${pid:-} ]] && kill -TERM "$pid" 2>/dev/null && it_wait_exit "$pid" 150; rm -rf "$work"; true' RETURN
    request="$work/request.json"
    it_windows_install_bundle "$bundle" "$iso" "$tools" "$request" "It-$(uuidgen | cut -c1-12)"
    export VMPANE_TEST_WIN_INSTALL=$request
    pid=$(it_start_helper "$bundle") || return 1
    unset VMPANE_TEST_WIN_INSTALL
    socket=$(it_socket "$bundle")

    # 1. Until Setup's first reboot.
    start=$SECONDS
    it_rpc "$socket" vm.start '{"headless": true}' >/dev/null || it_fail "vm.start failed" || return 1
    it_wait_for 2400 bash -c "jq -e .mediaEjected '$bundle/install/install.json' >/dev/null 2>&1" \
        || it_fail "Setup did not reboot within 40 min (at $(it_install_phase "$bundle"))" || return 1
    echo "win-install-resume: Setup rebooted after $(((SECONDS - start) / 60)) min; killing the helper"
    attempts=$(jq -r .attempts "$bundle/install/install.json")
    jq -e '[.removable[].id] | index("windows") | not' "$bundle/config.json" >/dev/null \
        || it_fail "the ejected Windows ISO is still in the config" || return 1

    # 2. A new helper resumes.
    kill -KILL "$pid"
    it_wait_exit "$pid" 15 || it_fail "the helper survived SIGKILL" || return 1
    pid=$(it_start_helper "$bundle") || return 1
    it_rpc "$socket" vm.start '{"headless": true}' >/dev/null || it_fail "vm.start after the restart failed" || return 1
    sleep 60  # past the first-boot key window
    [[ $(it_install_phase "$bundle") == setupRunning ]] \
        || it_fail "resumed in $(it_install_phase "$bundle"), not setupRunning" || return 1
    [[ $(jq -r .attempts "$bundle/install/install.json") == "$attempts" ]] \
        || it_fail "the restart counted a new first boot (key presses)" || return 1
    [[ $(it_state "$bundle") == running ]] || it_fail "the VM is not running after the restart" || return 1

    # 3. Cancel.
    it_rpc "$socket" vm.install.cancel >/dev/null || it_fail "vm.install.cancel failed" || return 1
    [[ ! -e $bundle/install/unattend.iso ]] || it_fail "unattend.iso is still there after cancel" || return 1
    it_wait_for 180 bash -c "[[ \$(/usr/bin/python3 '$VMPANE_ROOT/itest/lib/rpc.py' '$socket' vm.info | jq -r .state) == stopped ]]" \
        || it_fail "the VM did not stop after cancel" || return 1
    it_wait_for 30 bash -c "jq -e '.install == null and .removable == []' '$bundle/config.json' >/dev/null" \
        || it_fail "cancel left $(jq -c '{install, removable}' "$bundle/config.json")" || return 1
    [[ $(it_install_phase "$bundle") == cancelled ]] || it_fail "install.json says $(it_install_phase "$bundle")" || return 1
    echo "win-install-resume: resumed without a new first boot; cancel stopped the VM and cleaned up"
    it_rpc "$socket" helper.shutdown >/dev/null
    it_wait_exit "$pid" 30 || true
    pid=
    return 0
}
