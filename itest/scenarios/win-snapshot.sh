# Snapshots and suspend on the QEMU backend with Windows: a live snapshot keeps the VM running and its
# restore resumes the saved session (desktop at once, no firmware/boot), suspend + start resumes likewise,
# a failed save leaves the VM running with nothing behind, and a disk snapshot of the stopped VM restores
# to a cold boot. In-guest checks (a file gone after restore, chkdsk) need the guest agent (Phase 07).
source "$VMPANE_ROOT/itest/lib/common.sh"
IT_SCENARIO=win-snapshot

# Seconds until the desktop shows after a start or restore of a resumed session (a cold boot takes ~20 s).
IT_RESUME_DESKTOP=10

scenario_run() {
    local golden work bundle pid socket start id result status
    golden=$(it_golden_windows) || { status=$?; return "$status"; }
    work=$(cd "$(mktemp -d /tmp/vp-wsn.XXXXXX)" && pwd -P)
    export VMPANE_SUPPORT_DIR="$work/s"
    mkdir -p "$VMPANE_SUPPORT_DIR/VMs"
    bundle="$VMPANE_SUPPORT_DIR/VMs/W.vmpane"
    it_clone_bundle "$golden" "$bundle"
    trap 'set +e; [[ -n ${pid:-} ]] && kill -TERM "$pid" 2>/dev/null && it_wait_exit "$pid" 150; chmod -R u+w "$work" 2>/dev/null; rm -rf "$work"; true' RETURN
    pid=$(it_start_helper "$bundle") || return 1
    socket=$(it_socket "$bundle")
    it_rpc "$socket" vm.start '{"headless": true}' >/dev/null || it_fail "vm.start failed" || return 1
    it_wait_windows_desktop "$socket" 90 || it_fail "no desktop" || return 1

    # 1. Live snapshot of the running guest; it keeps running.
    start=$SECONDS
    id=$(it_rpc "$socket" vm.snapshot.create '{"name": "live", "kind": "live"}' | jq -r '.id // empty')
    [[ -n $id ]] || it_fail "live snapshot failed" || return 1
    echo "win-snapshot: live snapshot of a 4 GiB guest in $((SECONDS - start)) s"
    [[ $(it_state "$bundle") == running ]] || it_fail "VM not running after the snapshot" || return 1

    # 2. Restore it: the saved session resumes (desktop at once).
    sleep 5
    start=$SECONDS
    result=$(it_rpc "$socket" vm.snapshot.restore "{\"id\": \"$id\"}") || it_fail "restore failed: $result" || return 1
    [[ $(jq -r .resumed <<<"$result") == true ]] || it_fail "restore did not resume: $result" || return 1
    it_wait_windows_desktop "$socket" "$IT_RESUME_DESKTOP" || it_fail "no desktop right after the restore" || return 1
    echo "win-snapshot: live restore to the desktop in $((SECONDS - start)) s"

    # 3. A save that cannot be written: the VM keeps running, nothing is left behind.
    chmod 500 "$bundle/current/state"
    if it_rpc "$socket" vm.snapshot.create '{"name": "fails", "kind": "live"}' >/dev/null; then
        it_fail "a snapshot into an unwritable state directory succeeded"; return 1
    fi
    chmod 700 "$bundle/current/state"
    [[ $(it_state "$bundle") == running ]] || it_fail "VM not running after the failed snapshot" || return 1
    [[ $(it_rpc "$socket" vm.snapshot.list | jq length) == 1 ]] || it_fail "unexpected snapshot count" || return 1

    # 4. Suspend, then start: resumes the session.
    start=$SECONDS
    it_rpc "$socket" vm.suspend >/dev/null || it_fail "vm.suspend failed" || return 1
    echo "win-snapshot: suspended in $((SECONDS - start)) s"
    [[ $(it_state "$bundle") == stopped ]] || it_fail "not stopped after suspend" || return 1
    [[ -f $bundle/current/state/state.qemu && -f $bundle/current/state/suspend.json ]] || it_fail "no saved state" || return 1
    ! pgrep -f "$VMPANE_SUPPORT_DIR/runtime" >/dev/null || it_fail "QEMU or swtpm still running after suspend" || return 1
    start=$SECONDS
    it_rpc "$socket" vm.start '{"headless": true}' >/dev/null || it_fail "start after suspend failed" || return 1
    it_wait_windows_desktop "$socket" "$IT_RESUME_DESKTOP" || it_fail "no desktop right after resuming" || return 1
    echo "win-snapshot: resumed to the desktop in $((SECONDS - start)) s"
    [[ -z $(ls "$bundle/current/state") ]] || it_fail "saved state not cleared after resuming" || return 1

    # 5. Disk snapshot of the stopped VM; its restore boots cold.
    it_rpc "$socket" vm.stop '{"mode": "graceful"}' >/dev/null
    it_wait_for 150 bash -c "[[ \$(/usr/bin/python3 '$VMPANE_ROOT/itest/lib/rpc.py' '$socket' vm.info | jq -r .state) == stopped ]]" \
        || it_fail "Windows did not shut down" || return 1
    id=$(it_rpc "$socket" vm.snapshot.create '{"name": "disk", "kind": "disk"}' | jq -r '.id // empty')
    [[ -n $id ]] || it_fail "disk snapshot failed" || return 1
    result=$(it_rpc "$socket" vm.snapshot.restore "{\"id\": \"$id\"}") || it_fail "disk restore failed: $result" || return 1
    it_rpc "$socket" vm.start '{"headless": true}' >/dev/null || it_fail "start after the disk restore failed" || return 1
    it_wait_windows_desktop "$socket" 90 || it_fail "no desktop after the disk restore" || return 1

    it_rpc "$socket" vm.stop '{"mode": "graceful"}' >/dev/null
    it_wait_for 150 bash -c "[[ \$(/usr/bin/python3 '$VMPANE_ROOT/itest/lib/rpc.py' '$socket' vm.info | jq -r .state) == stopped ]]"
    it_rpc "$socket" helper.shutdown >/dev/null
    it_wait_exit "$pid" 30 || true
    pid=
    return 0
}
