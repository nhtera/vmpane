# The agent kill switch (Phase 10, Red Team #1) with no app running: while an MCP agent runs a long command and
# pulls a 1 GiB file and a script's port forward is up, `vmpane mcp kill` stops all of it within ~1 s (the command
# killed in the guest, the transfer cut, the forward down) and new agent calls are refused; the app's release
# brings the forward back. Needs an app built with the Linux guest tools. Sourced by scripts/itest.sh.

source "$VMPANE_ROOT/itest/lib/common.sh"
IT_SCENARIO=mcp-killswitch

it_agent_connected() { [[ $(it_rpc "$socket" agent.status | jq -r .connected) == true ]]; }
it_agent_exec() { /usr/bin/python3 "$VMPANE_ROOT/itest/lib/agent_exec.py" "$socket" "$@"; }

scenario_run() {
    local work bundle pid socket cli port id
    cli="$APP/Contents/Helpers/vmpane"
    [[ -f "$APP/Contents/Resources/GuestTools/linux/SHA256SUMS" ]] \
        || { echo "mcp-killswitch: the app has no Linux guest tools" >&2; return 77; }
    it_boot_linux_clone || return 1
    trap 'set +e; [[ -n ${pid:-} ]] && kill -9 "$pid" 2>/dev/null; rm -rf "$work"; true' RETURN
    it_rpc "$socket" vm.input.text '{"text": "VMPANE-INSTALL-AGENT\n"}' >/dev/null
    it_wait_for 60 grep -qa 'VMPANE-AGENT-INSTALLED rc=0' "$bundle/logs/serial.log" || it_fail "the agent did not install" || return 1
    it_wait_for 30 it_agent_connected || it_fail "the agent did not connect" || return 1
    it_set_policy admin || it_fail "cannot set the policy" || return 1
    export VMPANE_EXCHANGE_DIR="$work/exchange"
    it_agent_exec 'head -c 1073741824 /dev/zero >/root/big.bin; mkdir -p /root/w; echo up >/root/w/f; setsid -f python3 -m http.server 8000 --directory /root/w >/dev/null 2>&1 </dev/null; sleep 1' >/dev/null \
        || it_fail "cannot prepare the guest" || return 1
    id=$("$cli" list --json | jq -r '.[0].shortId')
    port=$((20000 + RANDOM % 20000))
    "$cli" port add "$id" "$port:8000" >/dev/null || it_fail "the script could not add a forward" || return 1
    [[ $(jq -r '.portForwards[] | select(.hostPort == '"$port"') | .origin' "$bundle/config.json") == agent ]] \
        || it_fail "a script's forward is not marked as an agent's" || return 1
    it_wait_for 10 bash -c "curl -sf --max-time 2 http://127.0.0.1:$port/f >/dev/null" || it_fail "the forward does not answer" || return 1

    /usr/bin/python3 - "$cli" "$socket" "$port" <<'PY' || { it_fail "the kill switch did not stop everything"; return 1; }
import os, subprocess, sys, time, urllib.request
sys.path.insert(0, os.path.join(os.environ["VMPANE_ROOT"], "itest/lib"))
from mcp_client import MCPClient

cli, socket, port = sys.argv[1], sys.argv[2], int(sys.argv[3])
signed = os.environ.get("VMPANE_ITEST_SIGNED") == "1"
client = MCPClient(cli)
vm = client.call("vm_list")["structuredContent"]["vms"][0]["id"]
long_exec = client.start("tools/call", {"name": "vm_exec", "arguments": {"vm": vm, "command": "sleep 300", "as": "admin"}})
pull = client.start("tools/call", {"name": "vm_file_pull", "arguments": {"vm": vm, "guest_path": "/root/big.bin", "host_path": "big.bin"}})
time.sleep(1.5)

killed_at = time.time()
subprocess.run([cli, "mcp", "kill"], check=True, capture_output=True)

def answered(call):
    try:
        client.wait(call, timeout=0.05)
        return True
    except Exception as error:
        if "Empty" not in type(error).__name__:
            raise
        return False

# On a signed app the tests are an agent too, refused while the switch is on: the cut call stands in for the guest's
# command, which is looked for after the release.
def exec_stopped():
    return answered(long_exec) if signed else not guest_sleep_alive()

def guest_sleep_alive():
    out = subprocess.run([sys.executable, os.path.join(os.environ["VMPANE_ROOT"], "itest/lib/agent_exec.py"), socket,
                          "pgrep -fx 'sleep 300' || true"], capture_output=True, text=True).stdout
    return out.strip() != ""

def forward_answers():
    try:
        urllib.request.urlopen(f"http://127.0.0.1:{port}/f", timeout=0.5)
        return True
    except Exception:
        return False

done = {}
while time.time() - killed_at < 5 and len(done) < 3:
    if "exec" not in done and exec_stopped():
        done["exec"] = time.time() - killed_at
    if "forward" not in done and not forward_answers():
        done["forward"] = time.time() - killed_at
    if "pull" not in done:
        try:
            answer = client.wait(pull, timeout=0.05)
            assert answer["result"].get("isError"), answer
            done["pull"] = time.time() - killed_at
        except Exception as error:
            if "Empty" not in type(error).__name__:
                raise
    time.sleep(0.05)
print("mcp-killswitch: stopped after " + ", ".join(f"{k} {v:.2f} s" for k, v in sorted(done.items())))
assert len(done) == 3, f"not everything stopped: {done}"
assert max(done.values()) < 1.5, f"too slow: {done}"
new = MCPClient(cli)
for tool, arguments in [("vm_list", {}), ("vm_screenshot", {"vm": vm, "max_edge": 320})]:
    refused = new.call(tool, **arguments)
    assert refused.get("isError") and "kill switch" in refused["content"][0]["text"], refused
print("mcp-killswitch: new agent calls are refused")
PY
    # The app lets agents act again (on a signed app as the app does it, itest/policy): the forward comes back.
    if it_signed; then
        "$VMPANE_ITEST_POLICY" release || it_fail "cannot release the switch" || return 1
    else
        it_rpc "$socket" mcp.enableAll >/dev/null || it_fail "the app could not release the switch" || return 1
    fi
    it_wait_for 5 bash -c "curl -sf --max-time 2 http://127.0.0.1:$port/f >/dev/null" || it_fail "the forward did not come back" || return 1
    [[ -z $(it_agent_exec "pgrep -fx 'sleep 300' || true") ]] || it_fail "the agent's command survived the switch" || return 1
    echo "mcp-killswitch: released by the app; the agent's forward is back"
}
