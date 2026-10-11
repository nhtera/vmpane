# The vmpane CLI against a running Linux VZ guest (Phase 10): list/info (--json), exec (output, exit codes
# passed through, stdin, --env), port add/list/rm (a real download through the forward), snapshot
# create/list/delete, screenshot, stop. Needs an app built with the Linux guest tools (exec uses the agent).
# Sourced by scripts/itest.sh with $APP set.

source "$VMPANE_ROOT/itest/lib/common.sh"
IT_SCENARIO=cli-e2e

it_agent_connected() { [[ $(it_rpc "$socket" agent.status | jq -r .connected) == true ]]; }

scenario_run() {
    local work bundle pid socket cli out rc id port
    cli="$APP/Contents/Helpers/vmpane"
    [[ -x $cli ]] || { it_fail "no vmpane in the app"; return 1; }
    [[ -f "$APP/Contents/Resources/GuestTools/linux/SHA256SUMS" ]] \
        || { echo "cli-e2e: the app has no Linux guest tools (guest-tools/build-linux.sh, then rebuild)" >&2; return 77; }
    it_boot_linux_clone || return 1
    # Agents' level for this VM, set as the app sets it (the bridge is the app to a development helper): tagged.
    it_rpc "$socket" vm.settings.apply '{"patch": {"mcp": {"policy": "admin", "confirmExec": false}}}' >/dev/null || it_fail "cannot set the policy" || return 1
    trap 'set +e; [[ -n ${pid:-} ]] && kill -9 "$pid" 2>/dev/null; rm -rf "$work"; true' RETURN
    it_rpc "$socket" vm.input.text '{"text": "VMPANE-INSTALL-AGENT\n"}' >/dev/null
    it_wait_for 60 grep -qa 'VMPANE-AGENT-INSTALLED rc=0' "$bundle/logs/serial.log" || it_fail "the agent did not install" || return 1
    it_wait_for 30 it_agent_connected || it_fail "the agent did not connect" || return 1

    # 1. list / info
    out=$("$cli" list --json) || it_fail "list failed" || return 1
    id=$(jq -r '.[0].shortId' <<<"$out")
    [[ $(jq -r '.[0].state' <<<"$out") == running && -n $id ]] || it_fail "list: $out" || return 1
    [[ $("$cli" info "$id" --json | jq -r .state) == running ]] || it_fail "info by short id" || return 1
    "$cli" list | grep -q running || it_fail "the table has no running VM" || return 1
    rc=0; "$cli" info no-such-vm 2>/dev/null || rc=$?
    [[ $rc == 66 ]] || it_fail "an unknown VM exits $rc, not 66" || return 1
    echo "cli-e2e: list and info ($id), unknown VM → 66"

    # 2. exec
    [[ $("$cli" exec "$id" --as admin -- uname -s) == Linux ]] || it_fail "exec uname" || return 1
    rc=0; "$cli" exec "$id" --as admin -- false || rc=$?
    [[ $rc == 1 ]] || it_fail "exec false exited $rc" || return 1
    rc=0; out=$("$cli" exec "$id" -- true 2>&1) || rc=$?
    [[ $rc != 0 && $out == *session* ]] || it_fail "as the user with nobody logged in: $rc $out" || return 1
    rc=0; "$cli" exec "$id" --as admin -- sh -c 'exit 42' || rc=$?
    [[ $rc == 42 ]] || it_fail "exit 42 came back as $rc" || return 1
    [[ $(printf 'piped\n' | "$cli" exec "$id" --as admin -- cat) == piped ]] || it_fail "stdin did not reach the command" || return 1
    [[ $("$cli" exec "$id" --as admin --env GREETING=hi -- sh -c 'echo $GREETING') == hi ]] || it_fail "--env" || return 1
    echo "cli-e2e: exec output, exit codes 1 and 42, stdin, --env"

    # 3. ports
    "$cli" exec "$id" --as admin -- sh -c 'mkdir -p /root/w && echo served >/root/w/f && setsid -f python3 -m http.server 8000 --directory /root/w >/dev/null 2>&1 </dev/null; sleep 1' \
        || it_fail "cannot start a web server" || return 1
    port=$((20000 + RANDOM % 20000))
    "$cli" port add "$id" "$port:8000" >/dev/null || it_fail "port add failed" || return 1
    "$cli" port list "$id" | grep -q listening || it_fail "port list: $("$cli" port list "$id")" || return 1
    [[ $(curl -sf --max-time 10 "http://127.0.0.1:$port/f") == served ]] || it_fail "nothing through the forward" || return 1
    "$cli" port rm "$id" "$port" || it_fail "port rm failed" || return 1
    if curl -sf --max-time 3 "http://127.0.0.1:$port/f" >/dev/null; then it_fail "the removed forward still answers"; return 1; fi
    echo "cli-e2e: port add/list/rm"

    # 4. snapshots and a screenshot
    "$cli" snapshot create "$id" "from the cli" >/dev/null || it_fail "snapshot create failed" || return 1
    "$cli" snapshot list "$id" | grep -q "from the cli" || it_fail "snapshot list" || return 1
    "$cli" snapshot delete "$id" "from the cli" || it_fail "snapshot delete" || return 1
    "$cli" screenshot "$id" -o "$work/shot.png" --max-edge 640 || it_fail "screenshot failed" || return 1
    [[ $(file -b "$work/shot.png") == PNG* ]] || it_fail "the screenshot is not a PNG" || return 1
    echo "cli-e2e: snapshot create/list/delete, screenshot"

    # 5. Policy: at observe, a script (no terminal) may look but not act: exit 77, recorded as a denial.
    it_rpc "$socket" vm.settings.apply '{"patch": {"mcp": {"policy": "observe"}}}' >/dev/null || it_fail "cannot lower the policy" || return 1
    "$cli" info "$id" >/dev/null || it_fail "info at observe" || return 1
    rc=0; "$cli" exec "$id" --as admin -- true </dev/null 2>/dev/null || rc=$?
    [[ $rc == 77 ]] || it_fail "exec at observe exited $rc, not 77" || return 1
    tail -1 "$bundle/logs/mcp-audit.jsonl" | jq -e '.result == "denied" and .identity == "cli" and .method == "agent.exec"' >/dev/null \
        || it_fail "no denial in the audit log: $(tail -1 "$bundle/logs/mcp-audit.jsonl")" || return 1
    # Hand-raising the level in config.json does not count (no tag).
    jq '.mcp.policy = "admin"' "$bundle/config.json" >"$work/c.json" && cp "$work/c.json" "$bundle/config.json"
    [[ $("$cli" list --json | jq length) == 0 ]] || it_fail "a hand-edited policy made the VM visible" || return 1
    it_rpc "$socket" vm.settings.apply '{"patch": {"mcp": {"policy": "admin", "confirmExec": false}}}' >/dev/null || it_fail "cannot raise the policy" || return 1
    echo "cli-e2e: at observe a script is refused (77, audited); a hand-edited level counts as off"

    # 6. stop
    [[ $("$cli" stop "$id" --force --json | jq -r .state) =~ ^(stopping|stopped)$ ]] || it_fail "stop" || return 1
    it_wait_for 30 bash -c "[[ \$('$cli' info '$id' --json | jq -r .state) == stopped ]]" || it_fail "the VM did not stop" || return 1
    echo "cli-e2e: stop --force"
}
