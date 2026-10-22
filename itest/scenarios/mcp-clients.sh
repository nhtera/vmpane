# The real AI clients (Claude Code, Codex CLI, Gemini CLI) against a running Linux VZ guest through `vmpane mcp`:
# each one, told in plain words, lists the VMs, takes a screenshot, clicks, types with vm_actions (the text arrives in
# the guest), reads the screen with vm_read_screen and runs `uname -s` (its output comes back); the audit log records
# each call (a batch and each of its actions), with the name the client gave.
# `vmpane mcp config <client> --apply` is checked in a temporary home (the real one is compared before and after).
# The clients run with their own sign-in but get VMPane only for this run (command-line options and a config in
# a temporary folder): no client config of the person's changes. Each client costs a few model calls, so the
# scenario runs only with VMPANE_ITEST_AI_CLIENTS=1, or a list of them ("codex gemini"); 77 otherwise, or without
# any of them installed.
# Needs an app built with the Linux guest tools. Sourced by scripts/itest.sh with $APP set.

source "$VMPANE_ROOT/itest/lib/common.sh"
IT_SCENARIO=mcp-clients

# Runs a command for at most $1 seconds (macOS has no timeout(1)).
mc_timeout() { perl -e 'alarm shift; exec @ARGV' "$@"; }
it_agent_connected() { [[ $(it_rpc "$socket" agent.status | jq -r .connected) == true ]]; }

# A fingerprint of the person's client configs (never printed): it must not change.
mc_real_configs() {
    local f
    for f in "$HOME/.claude.json" "$HOME/.codex/config.toml" "$HOME/.gemini/settings.json"; do
        [[ -f $f ]] && jq -c '.mcpServers? // empty' "$f" 2>/dev/null | shasum -a 256
        [[ $f == *.toml && -f $f ]] && shasum -a 256 "$f"
    done
    true
}

# Asks client $1 (claude, codex, gemini) to drive the VM; its words go to $work/$1.out.
mc_prompt() {
    cat <<EOF
Use only the tools of the MCP server vmpane_itest. Do these steps in order, without asking me anything:
1. vm_list, and take the id of the running VM.
2. vm_screenshot of that VM.
3. vm_click on that VM at x=10, y=10.
4. vm_actions on that VM with one action: type the text "hello from $1", with submit true.
5. vm_read_screen of that VM.
6. vm_exec in that VM with argv ["uname", "-s"] and as "admin".
Then reply with one line: RESULT: followed by the stdout of step 6.
EOF
}

mc_run_client() {
    local client=$1 out="$work/$1.out" dir="$work/$1"
    mkdir -p "$dir"
    case $client in
        claude)
            jq -n --arg cmd "$cli" --arg s "$VMPANE_SUPPORT_DIR" --arg x "$VMPANE_EXCHANGE_DIR" \
                '{mcpServers: {vmpane_itest: {command: $cmd, args: ["mcp"], env: {VMPANE_SUPPORT_DIR: $s, VMPANE_EXCHANGE_DIR: $x}}}}' \
                >"$dir/mcp.json"
            (cd "$dir" && mc_timeout 600 claude -p "$(mc_prompt claude)" --mcp-config "$dir/mcp.json" --strict-mcp-config \
                --allowedTools "mcp__vmpane_itest__*" --output-format text) >"$out" 2>&1
            ;;
        codex)
            # (VMPANE_ITEST_CODEX_MODEL: a model for this run, when the configured one is not available to the account)
            (cd "$dir" && mc_timeout 600 codex exec --skip-git-repo-check --sandbox read-only \
                ${VMPANE_ITEST_CODEX_MODEL:+-m "$VMPANE_ITEST_CODEX_MODEL"} \
                -c 'approval_policy="never"' \
                -c "mcp_servers.vmpane_itest.command=\"$cli\"" -c 'mcp_servers.vmpane_itest.args=["mcp"]' \
                -c 'mcp_servers.vmpane_itest.default_tools_approval_mode="approve"' \
                -c "mcp_servers.vmpane_itest.env={VMPANE_SUPPORT_DIR=\"$VMPANE_SUPPORT_DIR\",VMPANE_EXCHANGE_DIR=\"$VMPANE_EXCHANGE_DIR\"}" \
                "$(mc_prompt codex)") >"$out" 2>&1 </dev/null
            ;;
        gemini)
            # With $GEMINI_API_KEY set the run signs in with it (Google's free sign-in no longer serves this client).
            mkdir -p "$dir/.gemini"
            jq -n --arg cmd "$cli" --arg s "$VMPANE_SUPPORT_DIR" --arg x "$VMPANE_EXCHANGE_DIR" --arg key "${GEMINI_API_KEY:+1}" \
                '{mcpServers: {vmpane_itest: {command: $cmd, args: ["mcp"], env: {VMPANE_SUPPORT_DIR: $s, VMPANE_EXCHANGE_DIR: $x}, trust: true}}}
                 + (if $key == "1" then {security: {auth: {selectedType: "gemini-api-key"}}} else {} end)' \
                >"$dir/.gemini/settings.json"
            (cd "$dir" && GEMINI_CLI_TRUST_WORKSPACE=true mc_timeout 600 gemini --yolo --allowed-mcp-server-names vmpane_itest \
                -p "$(mc_prompt gemini)") >"$out" 2>&1 </dev/null
            ;;
    esac
}

# What client $1 did: its answer, the typed text in the guest, and its calls in the audit log.
mc_check_client() {
    local client=$1 tool calls
    mkdir -p "$VMPANE_ROOT/build/itest-logs"
    cp "$work/$client.out" "$VMPANE_ROOT/build/itest-logs/mcp-clients-$client.out"  # what it said, kept for a failure
    grep -q 'RESULT: *Linux' "$work/$client.out" \
        || { it_fail "$client did not report uname (build/itest-logs/mcp-clients-$client.out)"; return 1; }
    it_wait_for 10 grep -qa "VMPANE-TYPED hello from $client" "$bundle/logs/serial.log" \
        || { it_fail "the text $client typed did not arrive in the guest"; return 1; }
    # (the helper audits its own methods: vm_screenshot, vm_click, vm_actions (the batch and its text), vm_read_screen
    # and vm_exec call these)
    calls=$(jq -r --arg after "$2" 'select(.ts > $after and .kind == "mcp" and .result == "ok") | .method' \
        "$bundle/logs/mcp-audit.jsonl" 2>/dev/null | sort -u | tr '\n' ' ')
    for method in vm.screenshot vm.input.pointer vm.input.batch vm.input.text vm.screen.read agent.exec; do
        [[ " $calls" == *" $method "* ]] || { it_fail "$client: no successful $method in the audit log (saw: $calls)"; return 1; }
    done
    echo "mcp-clients: $client listed, took a screenshot, clicked, typed in a batch (arrived), read the screen and ran uname ($(jq -r --arg after "$2" \
        'select(.ts > $after and .kind == "mcp") | .client' "$bundle/logs/mcp-audit.jsonl" | sort -u | tr '\n' ' '))"
}

# `vmpane mcp config <client> --apply` in a temporary home: the file (or `claude mcp add`) names this vmpane.
mc_check_apply() {
    local client=$1 home="$work/home-$1"
    mkdir -p "$home"
    HOME=$home "$cli" mcp config "$client" --apply >"$work/apply-$client.out" 2>&1 \
        || { it_fail "mcp config $client --apply failed: $(tail -3 "$work/apply-$client.out")"; return 1; }
    case $client in
        claude) jq -e --arg cmd "$cli" '.mcpServers.vmpane.command == $cmd' "$home/.claude.json" >/dev/null ;;
        codex) grep -q '^\[mcp_servers.vmpane\]' "$home/.codex/config.toml" && grep -qF "\"$cli\"" "$home/.codex/config.toml" ;;
        gemini) jq -e --arg cmd "$cli" '.mcpServers.vmpane.command == $cmd' "$home/.gemini/settings.json" >/dev/null ;;
    esac || { it_fail "mcp config $client --apply did not add vmpane in the temporary home"; return 1; }
}

scenario_run() {
    local work bundle pid socket cli client clients=() before after
    local wanted=${VMPANE_ITEST_AI_CLIENTS:-}
    [[ -n $wanted ]] || { echo "mcp-clients: set VMPANE_ITEST_AI_CLIENTS=1 (uses the clients' model quota)" >&2; return 77; }
    [[ $wanted == 1 ]] && wanted="claude codex gemini"
    for client in $wanted; do command -v "$client" >/dev/null && clients+=("$client"); done
    ((${#clients[@]})) || { echo "mcp-clients: none of claude, codex, gemini is installed" >&2; return 77; }
    cli="$APP/Contents/Helpers/vmpane"
    [[ -f "$APP/Contents/Resources/GuestTools/linux/SHA256SUMS" ]] \
        || { echo "mcp-clients: the app has no Linux guest tools (guest-tools/build-linux.sh, then rebuild)" >&2; return 77; }
    before=$(mc_real_configs)
    it_boot_linux_clone || return 1
    trap 'set +e; [[ -n ${pid:-} ]] && kill -9 "$pid" 2>/dev/null; rm -rf "$work"; true' RETURN
    it_rpc "$socket" vm.input.text '{"text": "VMPANE-INSTALL-AGENT\n"}' >/dev/null
    it_wait_for 60 grep -qa 'VMPANE-AGENT-INSTALLED rc=0' "$bundle/logs/serial.log" || it_fail "the agent did not install" || return 1
    it_wait_for 30 it_agent_connected || it_fail "the agent did not connect" || return 1
    it_set_policy admin || it_fail "cannot set the policy" || return 1
    export VMPANE_EXCHANGE_DIR="$work/exchange"

    for client in "${clients[@]}"; do
        mc_check_apply "$client" || return 1
        local since
        since=$(date -u +%Y-%m-%dT%H:%M:%S)
        mc_run_client "$client" || true
        mc_check_client "$client" "$since" || return 1
    done
    echo "mcp-clients: mcp config --apply added vmpane for ${clients[*]} in a temporary home"

    after=$(mc_real_configs)
    [[ $before == "$after" ]] || it_fail "a client config in the real home changed" || return 1
    it_rpc "$socket" vm.stop '{"mode": "force"}' >/dev/null
    it_rpc "$socket" helper.shutdown >/dev/null
    it_wait_exit "$pid" 30 || true
    pid=
    return 0
}
