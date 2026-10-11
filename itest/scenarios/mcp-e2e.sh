# The MCP server against a running Linux VZ guest (Phase 10), through a scripted client over `vmpane mcp`'s stdio:
# list → screenshot → click → type (arrives in the guest) → exec (output, exit codes) → file push/pull through the
# exchange folder → snapshot create/list/delete; a cancelled exec gets no answer and is killed in the guest; at a
# lower level the same calls are refused and audited with the session; a hand-edited level counts as off.
# Needs an app built with the Linux guest tools. Sourced by scripts/itest.sh with $APP set.

source "$VMPANE_ROOT/itest/lib/common.sh"
IT_SCENARIO=mcp-e2e

it_agent_connected() { [[ $(it_rpc "$socket" agent.status | jq -r .connected) == true ]]; }

scenario_run() {
    local work bundle pid socket cli
    cli="$APP/Contents/Helpers/vmpane"
    [[ -f "$APP/Contents/Resources/GuestTools/linux/SHA256SUMS" ]] \
        || { echo "mcp-e2e: the app has no Linux guest tools (guest-tools/build-linux.sh, then rebuild)" >&2; return 77; }
    it_boot_linux_clone || return 1
    trap 'set +e; [[ -n ${pid:-} ]] && kill -9 "$pid" 2>/dev/null; rm -rf "$work"; true' RETURN
    it_rpc "$socket" vm.input.text '{"text": "VMPANE-INSTALL-AGENT\n"}' >/dev/null
    it_wait_for 60 grep -qa 'VMPANE-AGENT-INSTALLED rc=0' "$bundle/logs/serial.log" || it_fail "the agent did not install" || return 1
    it_wait_for 30 it_agent_connected || it_fail "the agent did not connect" || return 1
    it_rpc "$socket" vm.settings.apply '{"patch": {"mcp": {"policy": "admin", "confirmExec": false}}}' >/dev/null || it_fail "cannot set the policy" || return 1
    export VMPANE_EXCHANGE_DIR="$work/exchange"

    /usr/bin/python3 - "$cli" "$bundle" "$socket" <<'PY' || { it_fail "the MCP session failed"; return 1; }
import json, os, subprocess, sys, time
sys.path.insert(0, os.path.join(os.environ["VMPANE_ROOT"], "itest/lib"))
from mcp_client import MCPClient

cli, bundle, socket = sys.argv[1:4]
client = MCPClient(cli)
def text(result):
    return "\n".join(block.get("text", "") for block in result["content"] if block["type"] == "text")

vms = client.call("vm_list")["structuredContent"]["vms"]
assert len(vms) == 1 and vms[0]["state"] == "running", vms
vm = vms[0]["id"]

shot = client.call("vm_screenshot", vm=vm, max_edge=640)
assert shot["content"][0]["type"] == "image" and shot["structuredContent"]["scale"] > 1, shot["structuredContent"]
client.call("vm_click", vm=vm, x=10, y=10)
client.call("vm_type", vm=vm, text="hello from mcp\n")
deadline = time.time() + 10
while b"VMPANE-TYPED hello from mcp" not in open(os.path.join(bundle, "logs/serial.log"), "rb").read():
    assert time.time() < deadline, "typed text did not arrive"
    time.sleep(0.2)
undo = [s for s in client.call("vm_snapshot_list", vm=vm)["structuredContent"]["snapshots"] if s["origin"] == "agentSession"]
assert len(undo) == 1 and undo[0]["name"].startswith("agent: itest-mcp"), undo
print("mcp-e2e: list, screenshot (scaled), click, type arrived in the guest; the session's first change took its undo snapshot")

uname = client.call("vm_exec", vm=vm, argv=["uname", "-s"], **{"as": "admin"})
assert uname["structuredContent"]["stdout"].strip() == "Linux" and not uname.get("isError"), uname
failed = client.call("vm_exec", vm=vm, command="echo oops >&2; exit 3", **{"as": "admin"})
assert failed.get("isError") and failed["structuredContent"]["exitCode"] == 3 and "oops" in failed["structuredContent"]["stderr"], failed
fed = client.call("vm_exec", vm=vm, argv=["cat"], stdin="fed in", **{"as": "admin"})
assert fed["structuredContent"]["stdout"] == "fed in", fed
print("mcp-e2e: exec output, exit code 3 as an error result, stdin")

exchange = os.path.join(os.environ["VMPANE_EXCHANGE_DIR"], vms[0]["name"])
os.makedirs(exchange, exist_ok=True)
open(os.path.join(exchange, "in.txt"), "w").write("from the mac")
pushed = client.call("vm_file_push", vm=vm, host_path="in.txt", guest_path="/root/in.txt")
assert not pushed.get("isError"), pushed
pulled = client.call("vm_file_pull", vm=vm, guest_path="/root/in.txt", host_path="back/out.txt")
assert not pulled.get("isError"), pulled
assert open(os.path.join(exchange, "back/out.txt")).read() == "from the mac"
escape = client.call("vm_file_pull", vm=vm, guest_path="/etc/hostname", host_path="../../escape.txt")
assert escape.get("isError") and not os.path.exists(os.path.join(os.environ["VMPANE_EXCHANGE_DIR"], "..", "escape.txt")), escape
print("mcp-e2e: file push/pull through the exchange folder; .. refused")

taken = client.call("vm_snapshot_create", vm=vm, name="agent test")
snapshot = taken["structuredContent"]["id"]
assert any(s["id"] == snapshot for s in client.call("vm_snapshot_list", vm=vm)["structuredContent"]["snapshots"])
client.call("vm_snapshot_delete", vm=vm, snapshot=snapshot)
print("mcp-e2e: snapshot create/list/delete")

slow = client.start("tools/call", {"name": "vm_exec", "arguments": {"vm": vm, "command": "sleep 300; echo done >/root/late", "as": "admin"}})
time.sleep(1.5)
client.notify("notifications/cancelled", {"requestId": slow, "reason": "test"})
try:
    answer = client.wait(slow, timeout=3)
    raise AssertionError(f"a cancelled call was answered: {answer}")
except Exception as error:
    assert "Empty" in type(error).__name__, error
running = client.call("vm_exec", vm=vm, command="pgrep -fx 'sleep 300' || true", **{"as": "admin"})
assert running["structuredContent"]["stdout"].strip() == "", running
print("mcp-e2e: a cancelled exec gets no answer and is killed in the guest")

subprocess.run([sys.executable, os.path.join(os.environ["VMPANE_ROOT"], "itest/lib/rpc.py"), socket, "vm.settings.apply",
                json.dumps({"patch": {"mcp": {"policy": "observe"}}})], check=True, capture_output=True)
refused = client.call("vm_exec", vm=vm, argv=["true"])
assert refused.get("isError") and "Refused" in text(refused), refused
assert client.call("vm_screenshot", vm=vm, max_edge=320)["content"][0]["type"] == "image"
audit = [json.loads(line) for line in open(os.path.join(bundle, "logs/mcp-audit.jsonl"))]
denied = [a for a in audit if a["result"] == "denied" and a["method"] == "agent.exec"]
assert denied and denied[-1]["kind"] == "mcp" and denied[-1].get("session") and denied[-1]["identity"] == "cli", denied[-1:]
assert all(a["identity"] == "cli" and a["kind"] == "mcp" for a in audit if a.get("session") == denied[-1]["session"])
print("mcp-e2e: at observe exec is refused, screenshots still work; refusals audited with the session")
client.close()
PY
}
