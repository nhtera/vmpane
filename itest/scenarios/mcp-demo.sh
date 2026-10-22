# A real Claude Code session for the website's agents section (agent edge, Phase 09): three VMs in one library
# (macOS, Ubuntu and Windows 11: clones of the goldens), stopped and opened to agents at Full control, and Claude Code
# asked in plain words to take each in turn: start it and wait for its guest tools, snapshot Windows first, write and
# run a small test in the system's own shell, read the screen, and stop it. The unedited transcript goes to
# build/itest-logs/mcp-demo.jsonl (the stream) and mcp-demo.txt (readable: the home folder written as ~, screenshots as
# [image]). Checks: each VM's audit log has its command, Windows has the snapshot, and all three are stopped again.
# Costs model calls, ~20 GiB and ~30 min: runs only with VMPANE_ITEST_MCP_DEMO=1 (77 otherwise). Unsigned apps (the
# itest bridge prepares the VMs). Sourced by scripts/itest.sh with $APP set.

source "$VMPANE_ROOT/itest/lib/common.sh"
IT_SCENARIO=mcp-demo

md_timeout() { perl -e 'alarm shift; exec @ARGV' "$@"; }
md_state() { it_rpc "$1" vm.info | jq -r .state; }

# Stops the VM behind socket $1 as its power button does (force after 120 s) and waits until it is stopped.
md_stop() {
    it_rpc "$1" vm.stop '{"mode": "graceful"}' >/dev/null
    it_wait_for 120 bash -c "[[ \$(/usr/bin/python3 '$VMPANE_ROOT/itest/lib/rpc.py' '$1' vm.info | jq -r .state) == stopped ]]" && return
    it_rpc "$1" vm.stop '{"mode": "force"}' >/dev/null
    it_wait_for 30 bash -c "[[ \$(/usr/bin/python3 '$VMPANE_ROOT/itest/lib/rpc.py' '$1' vm.info | jq -r .state) == stopped ]]"
}

# Names the VM behind socket $1 ($2) and opens it to agents at Full control (stopping a VM needs it), without questions
# or undo snapshots.
md_open() {
    it_rpc "$1" vm.settings.apply "$(jq -n --arg name "$2" \
        '{patch: {name: $name, mcp: {policy: "admin", confirmExec: false, autoSnapshot: false}}}')" >/dev/null
}

md_prompt() {
    cat <<'EOF'
Use only the tools of the MCP server vmpane. Three VMs in VMPane are stopped: macOS, Ubuntu and Windows 11. Take them
one at a time, in that order, and stop each one before you start the next:
1. Start it, and wait until its guest tools answer.
2. On Windows only: first take a snapshot named "before tests".
3. Write a small test in the system's own shell (zsh on macOS, sh on Ubuntu, PowerShell on Windows) that checks that
   6 × 7 is 42 and prints PASS or FAIL, run it with vm_exec, and note its output.
4. Read its screen with vm_read_screen and describe what is on it in one sentence.
5. Stop it, and wait until it is stopped.
Do not ask me anything. At the end, reply with a short table: VM, test output, what was on the screen.
EOF
}

scenario_run() {
    local work golden status helper cli="$APP/Contents/Helpers/vmpane" pids=() mac win lin out="$VMPANE_ROOT/build/itest-logs"
    [[ ${VMPANE_ITEST_MCP_DEMO:-0} == 1 ]] || { echo "mcp-demo: runs with VMPANE_ITEST_MCP_DEMO=1 (model calls)" >&2; return 77; }
    command -v claude >/dev/null || { echo "mcp-demo: Claude Code is not installed" >&2; return 77; }
    (($(df -g "$HOME" | awk 'NR == 2 {print $4}') >= 25)) || { echo "mcp-demo: needs 25 GiB free" >&2; return 77; }
    work=$(mktemp -d /tmp/vp-demo.XXXXXX)
    export VMPANE_SUPPORT_DIR="$work/s"
    mkdir -p "$VMPANE_SUPPORT_DIR/VMs" "$out"
    trap 'set +e; for p in "${pids[@]}"; do kill -TERM "$p" 2>/dev/null; done; for p in "${pids[@]}"; do it_wait_exit "$p" 150; done; rm -rf "$work"; trap - RETURN; true' RETURN

    # Ubuntu: the Linux golden with VMPane's guest tools installed from its share, as a person would.
    golden=$(it_golden_linux) || return 1
    it_clone_bundle "$golden" "$VMPANE_SUPPORT_DIR/VMs/Ubuntu.vmpane"
    helper=$(it_start_helper "$VMPANE_SUPPORT_DIR/VMs/Ubuntu.vmpane") || return 1
    pids+=("$helper")
    lin=$(it_socket "$VMPANE_SUPPORT_DIR/VMs/Ubuntu.vmpane")
    it_rpc "$lin" vm.start '{"headless": true}' >/dev/null || it_fail "Ubuntu did not start" || return 1
    it_wait_for 60 grep -q VMPANE-ITEST-READY "$VMPANE_SUPPORT_DIR/VMs/Ubuntu.vmpane/logs/serial.log" || it_fail "Ubuntu: no ready marker" || return 1
    it_rpc "$lin" vm.input.text '{"text": "VMPANE-INSTALL-AGENT\n"}' >/dev/null
    it_wait_for 90 grep -qa 'VMPANE-AGENT-INSTALLED rc=0' "$VMPANE_SUPPORT_DIR/VMs/Ubuntu.vmpane/logs/serial.log" \
        || it_fail "Ubuntu: the guest tools did not install" || return 1
    md_open "$lin" "Ubuntu" && md_stop "$lin" || it_fail "Ubuntu did not stop" || return 1

    # Windows 11: the golden, signing in by itself (as after its unattended install).
    golden=$(it_golden_windows) || { status=$?; return "$status"; }
    it_clone_bundle "$golden" "$VMPANE_SUPPORT_DIR/VMs/Windows.vmpane"
    helper=$(it_start_helper "$VMPANE_SUPPORT_DIR/VMs/Windows.vmpane") || return 1
    pids+=("$helper")
    win=$(it_socket "$VMPANE_SUPPORT_DIR/VMs/Windows.vmpane")
    it_rpc "$win" vm.start '{"headless": true}' >"$work/win-start.out" 2>&1 \
        || { cat "$work/win-start.out" >&2; tail -5 "$VMPANE_SUPPORT_DIR"/helper-*.log >&2; it_fail "Windows did not start"; return 1; }
    it_wait_for 180 bash -c "/usr/bin/python3 '$VMPANE_ROOT/itest/lib/rpc.py' '$win' agent.status | jq -e .connected >/dev/null" \
        || it_fail "Windows: the guest tools did not connect" || return 1
    it_windows_autologon "$win" "$work" || it_fail "Windows: no automatic sign-in" || return 1
    md_open "$win" "Windows 11" && md_stop "$win" || it_fail "Windows did not stop" || return 1

    # macOS: the golden with a user and the guest tools, as it is.
    golden=$(it_golden_macos_user) || { status=$?; return "$status"; }
    it_clone_bundle "$golden" "$VMPANE_SUPPORT_DIR/VMs/macOS.vmpane"
    helper=$(it_start_helper "$VMPANE_SUPPORT_DIR/VMs/macOS.vmpane") || return 1
    pids+=("$helper")
    mac=$(it_socket "$VMPANE_SUPPORT_DIR/VMs/macOS.vmpane")
    md_open "$mac" "macOS" || it_fail "cannot open macOS to agents" || return 1

    jq -n --arg cmd "$cli" --arg s "$VMPANE_SUPPORT_DIR" '{mcpServers: {vmpane: {command: $cmd, args: ["mcp"], env: {VMPANE_SUPPORT_DIR: $s}}}}' \
        >"$work/mcp.json"
    (cd "$work" && md_timeout 2400 claude -p "$(md_prompt)" --mcp-config "$work/mcp.json" --strict-mcp-config \
        --allowedTools "mcp__vmpane__*" --output-format stream-json --verbose) >"$out/mcp-demo.jsonl" 2>"$work/claude.err" \
        || { tail -5 "$work/claude.err" >&2; it_fail "Claude Code did not finish"; return 1; }
    /usr/bin/python3 "$VMPANE_ROOT/itest/lib/demo_transcript.py" "$out/mcp-demo.jsonl" "$HOME" "$VMPANE_SUPPORT_DIR" >"$out/mcp-demo.txt" \
        || it_fail "the transcript could not be read" || return 1

    local name socket
    for name in macOS Ubuntu Windows; do
        socket=$(it_socket "$VMPANE_SUPPORT_DIR/VMs/$name.vmpane")
        jq -e 'select(.method == "agent.exec" and .result == "ok")' "$VMPANE_SUPPORT_DIR/VMs/$name.vmpane/logs/mcp-audit.jsonl" >/dev/null \
            || it_fail "$name: no command ran" || return 1
        [[ $(md_state "$socket") == stopped ]] || it_fail "$name was left running" || return 1
    done
    it_rpc "$win" vm.snapshot.list | jq -e 'map(.name) | index("before tests")' >/dev/null \
        || it_fail "Windows has no \"before tests\" snapshot" || return 1
    echo "mcp-demo: Claude Code took macOS, Ubuntu and Windows in turn ($(grep -c '^→ ' "$out/mcp-demo.txt") tool calls); transcript in build/itest-logs/mcp-demo.txt"
}
