# Suspend on the VZ backend survives a helper restart (resume ≤ 10 s, same boot), and a state from
# another generation is discarded: cold boot, state deleted, never retried.
source "$VMPANE_ROOT/itest/lib/common.sh"
IT_SCENARIO=vz-suspend

scenario_run() {
    local work bundle pid socket
    trap 'set +e; [[ -n ${pid:-} ]] && kill -9 "$pid" 2>/dev/null; rm -rf "${work:-/nonexistent}"; true' RETURN
    it_boot_linux_clone || return 1
    local before boot
    before=$(it_next_tick "$bundle" "$(it_log_size "$bundle")") || it_fail "no ticks" || return 1
    read -r _ boot <<<"$before"

    # 1. Suspend, end the helper, start a new one, resume.
    [[ $(it_rpc "$socket" vm.suspend | jq -r .state) == stopped ]] || it_fail "suspend failed" || return 1
    ls "$bundle/current/state/suspend.vzvmsave" "$bundle/current/state/suspend.json" >/dev/null || it_fail "no saved state" || return 1
    it_rpc "$socket" helper.shutdown >/dev/null
    it_wait_exit "$pid"
    pid=$(it_start_helper "$bundle") || return 1
    local start=$SECONDS offset
    offset=$(it_log_size "$bundle")
    it_rpc "$socket" vm.start '{"headless": true}' >/dev/null || it_fail "start after suspend failed" || return 1
    local after
    after=$(it_next_tick "$bundle" "$offset" 10) || it_fail "no tick within 10 s of resuming" || return 1
    echo "resumed in $((SECONDS - start)) s"
    [[ ${after#* } == "$boot" ]] || it_fail "resume rebooted the guest" || return 1
    [[ -z $(ls "$bundle/current/state") ]] || it_fail "state not removed after resuming" || return 1

    # 2. A state from another generation: cold boot, state deleted.
    [[ $(it_rpc "$socket" vm.suspend | jq -r .state) == stopped ]] || it_fail "second suspend failed" || return 1
    jq --arg g "$(uuidgen)" '.generationId = $g' "$bundle/current/generation.json" >"$bundle/gen.tmp" \
        && mv "$bundle/gen.tmp" "$bundle/current/generation.json"
    offset=$(it_log_size "$bundle")
    it_rpc "$socket" vm.start '{"headless": true}' >/dev/null || it_fail "start with stale state failed" || return 1
    [[ -z $(ls "$bundle/current/state") ]] || it_fail "stale state was not deleted" || return 1
    it_wait_for 60 bash -c "tail -c +$((offset + 1)) '$bundle/logs/serial.log' | grep -aq VMPANE-ITEST-READY" \
        || it_fail "no cold boot after the stale state" || return 1
    after=$(it_next_tick "$bundle" "$offset") || it_fail "no ticks after cold boot" || return 1
    [[ ${after#* } != "$boot" ]] || it_fail "expected a new boot" || return 1

    it_rpc "$socket" vm.stop '{"mode": "force"}' >/dev/null
    it_rpc "$socket" helper.shutdown >/dev/null
    it_wait_exit "$pid"
    pid=
    return 0
}
