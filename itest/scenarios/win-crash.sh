# Crashes on the QEMU backend, each on a fresh clone of the golden Windows VM (two hard kills in a row send
# Windows into Automatic Repair, S2): kill -9 of QEMU and of swtpm put the VM in the error state with no
# process left behind, and a new start boots to the desktop; kill -9 of the helper leaves QEMU running
# with the bundle lock, so a relaunched helper reaps it first and runs exactly one QEMU (Red Team #2).
source "$VMPANE_ROOT/itest/lib/common.sh"
IT_SCENARIO=win-crash

# Clone the golden into its own support directory (each case is a separate Mac: clones share the golden's
# VM id), start a helper and the VM; sets bundle, pid, socket.
win_crash_boot() {
    export VMPANE_SUPPORT_DIR="$work/$1"
    mkdir -p "$VMPANE_SUPPORT_DIR/VMs"
    bundle="$VMPANE_SUPPORT_DIR/VMs/$1.vmpane"
    it_clone_bundle "$golden" "$bundle"
    pid=$(it_start_helper "$bundle") || return 1
    socket=$(it_socket "$bundle")
    it_rpc "$socket" vm.start '{"headless": true}' >/dev/null || { it_fail "vm.start failed"; return 1; }
    it_wait_windows_desktop "$socket" 90 || { it_fail "no desktop"; return 1; }
}

# The recorded children (swtpm, QEMU) of bundle $1, as "pid name" lines.
win_crash_children() {
    jq -r .process.pid "$VMPANE_SUPPORT_DIR/run/$(it_sid "$1").children" 2>/dev/null | while read -r child; do
        ps -o pid=,comm= -p "$child" | awk '{n = split($2, p, "/"); print $1, p[n]}'
    done
}

win_crash_child() { win_crash_children "$1" | awk -v name="$2" '$2 == name {print $1}'; }

scenario_run() {
    local work bundle pid socket status victim program children
    golden=$(it_golden_windows) || { status=$?; return "$status"; }
    work=$(cd "$(mktemp -d /tmp/vp-wc.XXXXXX)" && pwd -P)
    trap 'set +e; [[ -n ${pid:-} ]] && kill -TERM "$pid" 2>/dev/null && it_wait_exit "$pid" 150; pkill -TERM -f "$work/"; rm -rf "$work"; true' RETURN

    # 1, 2. QEMU or swtpm killed: error state, nothing left, and the VM starts again.
    for program in qemu-system-aarch64 swtpm; do
        win_crash_boot "${program%%-*}" || return 1
        children=$(win_crash_children "$bundle" | awk '{print $1}' | paste -sd, -)
        victim=$(win_crash_child "$bundle" "$program")
        [[ -n $victim ]] || it_fail "no $program child" || return 1
        kill -9 "$victim"
        it_wait_for 35 bash -c "[[ \$(/usr/bin/python3 '$VMPANE_ROOT/itest/lib/rpc.py' '$socket' vm.info | jq -r .state) == error ]]" \
            || it_fail "no error state after kill -9 of $program" || return 1
        it_wait_for 35 bash -c "! ps -p $children >/dev/null" || it_fail "processes left after kill -9 of $program" || return 1
        echo "win-crash: kill -9 $program → error state, no process left"
        it_rpc "$socket" vm.start '{"headless": true}' >/dev/null || it_fail "restart after the $program crash failed" || return 1
        it_wait_windows_desktop "$socket" 120 || it_fail "no desktop after the $program crash" || return 1
        it_rpc "$socket" vm.stop '{"mode": "graceful"}' >/dev/null
        it_wait_for 150 bash -c "[[ \$(/usr/bin/python3 '$VMPANE_ROOT/itest/lib/rpc.py' '$socket' vm.info | jq -r .state) == stopped ]]" \
            || it_fail "no clean shutdown after the $program crash" || return 1
        it_rpc "$socket" helper.shutdown >/dev/null
        it_wait_exit "$pid" 30 || true
        pid=
    done

    # 3. Helper killed: QEMU keeps the disks; the next helper reaps it and runs exactly one QEMU.
    win_crash_boot helper || return 1
    victim=$(win_crash_child "$bundle" qemu-system-aarch64)
    kill -9 "$pid"
    it_wait_exit "$pid" 10 || it_fail "helper did not die" || return 1
    ps -p "$victim" >/dev/null || it_fail "QEMU died with the helper (it should keep running until reaped)" || return 1
    pid=$(it_start_helper "$bundle") || return 1
    ! ps -p "$victim" >/dev/null || it_fail "the new helper did not reap the old QEMU" || return 1
    it_rpc "$socket" vm.start '{"headless": true}' >/dev/null || it_fail "start after the helper crash failed" || return 1
    [[ $(pgrep -f "$bundle/" | xargs ps -o comm= -p 2>/dev/null | grep -c qemu-system) == 1 ]] \
        || it_fail "not exactly one QEMU for the VM" || return 1
    it_wait_windows_desktop "$socket" 120 || it_fail "no desktop after the helper crash" || return 1
    echo "win-crash: kill -9 helper → relaunch reaped QEMU, one QEMU, desktop"
    it_rpc "$socket" vm.stop '{"mode": "graceful"}' >/dev/null
    it_wait_for 150 bash -c "[[ \$(/usr/bin/python3 '$VMPANE_ROOT/itest/lib/rpc.py' '$socket' vm.info | jq -r .state) == stopped ]]"
    it_rpc "$socket" helper.shutdown >/dev/null
    it_wait_exit "$pid" 30 || true
    pid=
    return 0
}
