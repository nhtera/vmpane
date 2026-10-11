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
    # The clone at policy admin (the CLI here is a non-interactive client; until policy tags are enforced the
    # level is written straight into the clone's config).
    local golden
    golden=$(it_golden_linux) || return 1
    work=$(mktemp -d /tmp/vp-it.XXXXXX)
    export VMPANE_SUPPORT_DIR="$work/s"
    mkdir -p "$VMPANE_SUPPORT_DIR/VMs"
    bundle="$VMPANE_SUPPORT_DIR/VMs/L.vmpane"
    it_clone_bundle "$golden" "$bundle"
    jq '.mcp.policy = "admin"' "$bundle/config.json" >"$work/c.json" && mv "$work/c.json" "$bundle/config.json"
    pid=$(it_start_helper "$bundle") || return 1
    socket=$(it_socket "$bundle")
    it_rpc "$socket" vm.start '{"headless": true}' >/dev/null || { it_fail "vm.start failed"; return 1; }
    it_wait_for 60 grep -q VMPANE-ITEST-READY "$bundle/logs/serial.log" || { it_fail "no ready marker"; return 1; }
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

    # 5. stop
    [[ $("$cli" stop "$id" --force --json | jq -r .state) =~ ^(stopping|stopped)$ ]] || it_fail "stop" || return 1
    it_wait_for 30 bash -c "[[ \$('$cli' info '$id' --json | jq -r .state) == stopped ]]" || it_fail "the VM did not stop" || return 1
    echo "cli-e2e: stop --force"
}
