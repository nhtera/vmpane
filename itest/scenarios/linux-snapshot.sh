# Live snapshot + restore on the VZ backend: the restored guest continues the snapshotted run (same boot,
# uptime back near the snapshot), a hardware change makes the restore cold-boot with a message, and a
# failed save leaves the VM running with nothing left behind.
source "$VMPANE_ROOT/itest/lib/common.sh"
IT_SCENARIO=linux-snapshot

scenario_run() {
    local work bundle pid socket
    trap 'set +e; [[ -n ${pid:-} ]] && kill -9 "$pid" 2>/dev/null; [[ -n ${bundle:-} ]] && chmod -R u+w "$bundle" 2>/dev/null; rm -rf "${work:-/nonexistent}"; true' RETURN
    it_boot_linux_clone || return 1

    # 1. Live snapshot of the running guest.
    local before snap_uptime boot id restored after
    before=$(it_next_tick "$bundle" "$(it_log_size "$bundle")") || it_fail "no ticks" || return 1
    read -r snap_uptime boot <<<"$before"
    local start=$SECONDS
    id=$(it_rpc "$socket" vm.snapshot.create '{"name": "live", "kind": "live"}' | jq -r .id) || it_fail "live snapshot failed" || return 1
    echo "live snapshot of a 2 GiB guest: $((SECONDS - start)) s (target < 10 s for 8 GiB)"
    [[ $(it_state "$bundle") == running ]] || it_fail "VM not running after the snapshot" || return 1

    # 2. Let it run on, then restore: same boot, uptime back near the snapshot point.
    sleep 8
    restored=$(it_rpc "$socket" vm.snapshot.restore "{\"id\": \"$id\"}") || it_fail "restore failed: $restored" || return 1
    [[ $(jq -r .resumed <<<"$restored") == true ]] || it_fail "restore did not resume: $restored" || return 1
    after=$(it_next_tick "$bundle" "$(it_log_size "$bundle")") || it_fail "no ticks after restore" || return 1
    read -r after_uptime after_boot <<<"$after"
    [[ $after_boot == "$boot" ]] || it_fail "restore rebooted the guest (boot $after_boot, was $boot)" || return 1
    ((after_uptime < snap_uptime + 6)) || it_fail "uptime $after_uptime: the guest did not go back to the snapshot ($snap_uptime)" || return 1
    echo "restored: uptime $after_uptime (snapshot at $snap_uptime), same boot"

    # 3. Forced save failure (state directory not writable): VM stays running, no partial snapshot.
    chmod 500 "$bundle/current/state"
    if it_rpc "$socket" vm.snapshot.create '{"name": "fails", "kind": "live"}' >/dev/null; then
        it_fail "a snapshot into an unwritable state directory succeeded"; return 1
    fi
    chmod 700 "$bundle/current/state"
    [[ $(it_state "$bundle") == running ]] || it_fail "VM not running after the failed snapshot" || return 1
    [[ -z $(ls "$bundle/snapshots" | grep -v -E '^[0-9A-F-]{36}$') ]] || it_fail "partial snapshot left behind" || return 1
    [[ $(it_rpc "$socket" vm.snapshot.list | jq length) == 1 ]] || it_fail "unexpected snapshot count" || return 1

    # 4. Changed hardware: the live state no longer fits, so the restore cold-boots, with a message.
    it_rpc "$socket" vm.stop '{"mode": "force"}' >/dev/null
    it_wait_for 20 bash -c "[[ \$(/usr/bin/python3 '$VMPANE_ROOT/itest/lib/rpc.py' '$socket' vm.info | jq -r .state) == stopped ]]"
    it_rpc "$socket" helper.shutdown >/dev/null
    it_wait_exit "$pid"
    jq '.cpu.count = 3' "$bundle/config.json" >"$bundle/config.tmp" && mv "$bundle/config.tmp" "$bundle/config.json" && chmod 600 "$bundle/config.json"
    pid=$(it_start_helper "$bundle") || return 1
    restored=$(it_rpc "$socket" vm.snapshot.restore "{\"id\": \"$id\"}") || it_fail "restore after hardware change failed" || return 1
    [[ $(jq -r .resumed <<<"$restored") == false ]] || it_fail "expected a cold boot: $restored" || return 1
    [[ -n $(jq -r '.message // empty' <<<"$restored") ]] || it_fail "no message for the cold boot" || return 1
    it_wait_for 60 bash -c "[[ \$(grep -a -c VMPANE-ITEST-READY '$bundle/logs/serial.log') -ge 2 ]]" || it_fail "cold boot did not come up" || return 1

    it_rpc "$socket" vm.stop '{"mode": "force"}' >/dev/null
    it_rpc "$socket" helper.shutdown >/dev/null
    it_wait_exit "$pid"
    pid=
    return 0
}
