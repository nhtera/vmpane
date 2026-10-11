# An app update while a VM runs (Red Team #5), without Sparkle's UI: `vmpane start` launches the helper from a
# versioned runtime copy; the app bundle is then replaced by a different version (its runtime version changes);
# the VM keeps running, and the new app's vmpane drives the old helper (info, pause, resume, screenshot, stop).
# Started again, the VM runs from the new version's runtime copy. Needs an app with the Linux guest tools (they
# are part of the runtime version). Sourced by scripts/itest.sh with $APP set.

source "$VMPANE_ROOT/itest/lib/common.sh"
IT_SCENARIO=update-under-load

# The pid and command line of the helper running the bundle.
uul_helper_pid() { jq -r .process.pid "$VMPANE_SUPPORT_DIR/run/$(it_sid "$bundle").pid" 2>/dev/null; }
uul_helper_path() { ps -o command= -p "$(uul_helper_pid)" | sed 's/ --.*//'; }
uul_state() { "$cli" info "$vm" --json 2>/dev/null | jq -r .state; }

scenario_run() {
    local work bundle golden app cli pid old_path new_path vm
    [[ -f "$APP/Contents/Resources/GuestTools/linux/SHA256SUMS" ]] \
        || { echo "update-under-load: the app has no Linux guest tools (guest-tools/build-linux.sh, then rebuild)" >&2; return 77; }
    golden=$(it_golden_linux) || return 1
    work=$(cd "$(mktemp -d /tmp/vp-uu.XXXXXX)" && pwd -P)
    export VMPANE_SUPPORT_DIR="$work/s"
    mkdir -p "$VMPANE_SUPPORT_DIR/VMs" "$work/Applications"
    bundle="$VMPANE_SUPPORT_DIR/VMs/L.vmpane"
    it_clone_bundle "$golden" "$bundle"
    vm=$(it_sid "$bundle")  # vmpane selects VMs by short id too
    app="$work/Applications/VMPane.app"
    cli="$app/Contents/Helpers/vmpane"
    cp -cR "$APP" "$app"
    trap 'set +e
          p=$(uul_helper_pid); [[ -n $p && $p != null ]] && kill -9 "$p" 2>/dev/null
          [[ -n ${pid:-} ]] && kill -9 "$pid" 2>/dev/null
          rm -rf "$work"; true' RETURN

    # The agents' level, set as the app sets it (through a helper started directly), so vmpane may start the VM.
    pid=$("$app/Contents/Helpers/VMPaneVM.app/Contents/MacOS/VMPaneVM" --vm "$bundle" --headless >>"$work/direct.log" 2>&1 & echo $!)
    it_wait_for 30 bash -c "/usr/bin/python3 '$VMPANE_ROOT/itest/lib/rpc.py' '$(it_socket "$bundle")' vm.info >/dev/null 2>&1" \
        || it_fail "the helper did not answer" || return 1
    it_rpc "$(it_socket "$bundle")" vm.settings.apply '{"patch": {"mcp": {"policy": "admin", "confirmExec": false}}}' >/dev/null \
        || it_fail "cannot set the policy" || return 1
    it_rpc "$(it_socket "$bundle")" helper.shutdown >/dev/null 2>&1 || true
    it_wait_exit "$pid" 15 || it_fail "the direct helper did not exit" || return 1
    pid=

    # 1. vmpane starts the VM: its helper runs from the runtime copy of this version.
    "$cli" start "$vm" >/dev/null || it_fail "vmpane start failed" || return 1
    it_wait_for 60 grep -q VMPANE-ITEST-READY "$bundle/logs/serial.log" || it_fail "no ready marker" || return 1
    old_path=$(uul_helper_path)
    [[ $old_path == "$VMPANE_SUPPORT_DIR/runtime/"* ]] || it_fail "the helper does not run from a runtime copy: $old_path" || return 1
    echo "update-under-load: running from ${old_path#"$VMPANE_SUPPORT_DIR/"}"

    # 2. The update: the app bundle replaced by another version (different guest tools → another runtime version).
    rm -rf "$app"
    cp -cR "$APP" "$app"
    echo "# update-under-load $(date +%s)" >>"$app/Contents/Resources/GuestTools/linux/SHA256SUMS"

    # 3. The VM did not notice; the new vmpane drives the old helper.
    [[ $(uul_state) == running ]] || it_fail "the VM is not running after the update" || return 1
    [[ $(uul_helper_path) == "$old_path" ]] || it_fail "the helper changed under the running VM" || return 1
    "$cli" pause "$vm" >/dev/null && [[ $(uul_state) == paused ]] || it_fail "pause through the new vmpane" || return 1
    "$cli" resume "$vm" >/dev/null && [[ $(uul_state) == running ]] || it_fail "resume through the new vmpane" || return 1
    "$cli" screenshot "$vm" -o "$work/shot.png" >/dev/null && [[ -s $work/shot.png ]] || it_fail "screenshot through the new vmpane" || return 1
    local tick
    tick=$(it_last_tick "$bundle" | cut -d' ' -f1)
    it_wait_for 30 bash -c "[[ \$(grep -a VMPANE-TICK '$bundle/logs/serial.log' | tail -1 | sed -E 's/.*uptime=([0-9]+).*/\\1/') -gt ${tick:-0} ]]" \
        || it_fail "the guest stopped ticking" || return 1
    echo "update-under-load: after the update the VM runs on; the new vmpane pauses, resumes and screenshots it"

    # 4. Stopped and started again, it runs from the new version.
    "$cli" stop "$vm" --force >/dev/null || it_fail "vmpane stop failed" || return 1
    it_wait_for 30 bash -c "[[ \$('$cli' info '$vm' --json 2>/dev/null | jq -r .state) == stopped ]]" || it_fail "the VM did not stop" || return 1
    pid=$(uul_helper_pid)
    it_rpc "$(it_socket "$bundle")" helper.shutdown >/dev/null 2>&1 || true
    it_wait_exit "$pid" 30 || it_fail "the old helper did not exit" || return 1
    pid=
    "$cli" start "$vm" >/dev/null || it_fail "vmpane start after the update failed" || return 1
    it_wait_for 60 bash -c "grep -c VMPANE-ITEST-READY '$bundle/logs/serial.log' | grep -qv '^1$'" || it_fail "no ready marker after the restart" || return 1
    new_path=$(uul_helper_path)
    [[ $new_path == "$VMPANE_SUPPORT_DIR/runtime/"* && $new_path != "$old_path" ]] \
        || it_fail "after the restart the helper runs from $new_path" || return 1
    echo "update-under-load: restarted from ${new_path#"$VMPANE_SUPPORT_DIR/"}"
    "$cli" stop "$vm" --force >/dev/null
    it_wait_for 30 bash -c "[[ \$('$cli' info '$vm' --json 2>/dev/null | jq -r .state) == stopped ]]" || true
    pid=$(uul_helper_pid)
    it_rpc "$(it_socket "$bundle")" helper.shutdown >/dev/null 2>&1 || true
    it_wait_exit "$pid" 30 || true
    pid=
}
