# The agent HUD in a real VM window (agent edge, Phase 05): while an MCP agent types in a Linux VM, the window's HUD
# shows Take Over; pressed (UI test, as a person does), the agent's next calls answer that the person took over, and
# after Resume they work again. Needs an unlocked GUI session. Sourced by scripts/itest.sh with $APP set.

source "$VMPANE_ROOT/itest/lib/common.sh"
IT_SCENARIO=agent-hud

scenario_run() {
    local work bundle pid socket cli agent stop log
    cli="$APP/Contents/Helpers/vmpane"
    it_boot_linux_clone || return 1  # (sets work, bundle, pid, socket)
    stop="$work/stop-agent"
    log="$work/agent.log"
    trap 'set +e; touch "$stop"; [[ -n ${agent:-} ]] && wait "$agent"; [[ -n ${pid:-} ]] && kill -9 "$pid" 2>/dev/null; rm -rf "$work"; true' RETURN
    it_set_policy control || it_fail "cannot set the policy" || return 1

    # The agent: one short line typed a second, until told to stop; each answer on a line of the log.
    /usr/bin/python3 - "$cli" "$stop" >"$log" 2>&1 <<'PY' &
import os, sys, time
sys.path.insert(0, os.path.join(os.environ["VMPANE_ROOT"], "itest/lib"))
from mcp_client import MCPClient

cli, stop = sys.argv[1:3]
client = MCPClient(cli)
vm = client.call("vm_list")["structuredContent"]["vms"][0]["id"]
n = 0
deadline = time.time() + 180
while not os.path.exists(stop) and time.time() < deadline:
    n += 1
    result = client.call("vm_actions", vm=vm, actions=[{"type": "type", "text": f"echo hud {n}", "submit": True}])
    text = " ".join(c.get("text", "") for c in result.get("content", []))
    print("taken" if result.get("isError") and "took over" in text else ("error " + text[:120] if result.get("isError") else "ok"), flush=True)
    time.sleep(1)
client.close()
PY
    agent=$!
    it_wait_for 30 grep -q '^ok' "$log" || { cat "$log" >&2; it_fail "the agent did not act"; return 1; }
    TEST_RUNNER_VMPANE_ITEST_AGENT_HUD=1 it_ui_vm_window VMPaneUITests/VMWindowUITests/testAgentHUDTakesOverAndResumes || return 1
    it_wait_for 15 bash -c "tail -1 '$log' | grep -q '^ok'" || { tail -5 "$log" >&2; it_fail "the agent did not act again after Resume"; return 1; }
    touch "$stop"
    wait "$agent"
    agent=
    grep -q '^taken' "$log" || { cat "$log" >&2; it_fail "no agent call was refused while the person had taken over"; return 1; }
    ! grep -q '^error' "$log" || { grep '^error' "$log" >&2; it_fail "an agent call failed otherwise"; return 1; }
    echo "agent-hud: the HUD's Take Over held the agent ($(grep -c '^taken' "$log") calls refused); Resume let it act again"
}
