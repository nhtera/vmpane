# Verified and batched input through `vmpane mcp` (agent edge, Phase 01), in real guests:
# Linux (VZ): a 4-action vm_actions types a line in one call and reports the screen changed; a pointer move on the
# text console reports unchanged; the typed text is not in the audit log; the kill switch stops a 3,000-character
# vm_actions within 300 ms and the actions after it never run.
# Windows (QEMU, frames from the helper app's SPICE client): vm_actions opens the Start menu (changed, with a box),
# vm_key esc closes it (after automatic sign-in: the golden shows the lock screen). Skips Windows without the golden
# VM or 15 GiB free.
# Sourced by scripts/itest.sh with $APP set.

source "$VMPANE_ROOT/itest/lib/common.sh"
IT_SCENARIO=mcp-actions

# The helper's verification timing lines (`verified: N captures from …`) since $1.
it_verify_log() {
    /usr/bin/log show --info --start "$1" --predicate 'eventMessage BEGINSWITH "verified: "' --style compact 2>/dev/null \
        | grep -o 'verified: .*' | sort | uniq -c | sort -rn | head -3
}

scenario_linux() {
    local work bundle pid socket cli since
    cli="$APP/Contents/Helpers/vmpane"
    since=$(date '+%Y-%m-%d %H:%M:%S')
    it_boot_linux_clone || return 1
    trap 'set +e; it_rpc "$socket" mcp.enableAll >/dev/null 2>&1; [[ -n ${pid:-} ]] && kill -9 "$pid" 2>/dev/null; rm -rf "$work"; trap - RETURN; true' RETURN
    it_set_policy control || it_fail "cannot set the policy" || return 1

    /usr/bin/python3 - "$cli" "$bundle" "$socket" <<'PY' || { it_fail "the MCP session failed"; return 1; }
import json, os, subprocess, sys, time
sys.path.insert(0, os.path.join(os.environ["VMPANE_ROOT"], "itest/lib"))
from mcp_client import MCPClient

cli, bundle, socket = sys.argv[1:4]
def bridge(method, params):  # as the app (the itest bridge), which the kill switch does not stop
    subprocess.run(["/usr/bin/python3", os.path.join(os.environ["VMPANE_ROOT"], "itest/lib/rpc.py"), socket, method,
                    json.dumps(params)], check=True, capture_output=True)
serial = os.path.join(bundle, "logs/serial.log")
def typed_lines():
    return [line.split(b"VMPANE-TYPED ", 1)[1].rstrip(b"\r\n").decode(errors="replace")
            for line in open(serial, "rb").read().splitlines() if b"VMPANE-TYPED " in line]
def wait_line(count, timeout=15):
    deadline = time.time() + timeout
    while len(typed_lines()) < count:
        assert time.time() < deadline, f"no typed line {count}: {typed_lines()}"
        time.sleep(0.1)
    return typed_lines()[count - 1]

client = MCPClient(cli)
vm = client.call("vm_list")["structuredContent"]["vms"][0]["id"]
client.call("vm_screenshot", vm=vm, max_edge=1024)
before = len(typed_lines())
started = time.time()
batch = client.call("vm_actions", vm=vm, actions=[
    {"type": "click", "x": 20, "y": 20}, {"type": "type", "text": "batch one"}, {"type": "key", "combo": "space"},
    {"type": "type", "text": "two", "submit": True}])
elapsed = time.time() - started
structured = batch["structuredContent"]
assert not batch.get("isError") and all(r["ok"] for r in structured["results"]) and len(structured["results"]) == 4, batch
assert wait_line(before + 1) == "batch one two", typed_lines()[-3:]
verified = structured["verified"]
assert verified["status"] == "changed" and verified["bbox"]["width"] > 0, verified
assert structured["screen"]["w"] <= 1024 and structured["screen"]["scale"] >= 1, structured["screen"]
print(f"mcp-actions linux: 4 actions in one call ({elapsed:.2f} s), the line arrived; verified {json.dumps(verified)}")

still = client.call("vm_move", vm=vm, x=30, y=30, settle_ms=500)["structuredContent"]["verified"]
assert still["status"] == "unchanged" and still["reason"] == "no_pixel_change", still
print(f"mcp-actions linux: a pointer move on the text console is unchanged ({still['waitedMs']} ms)")

audit = open(os.path.join(bundle, "logs/mcp-audit.jsonl")).read()
assert "batch one" not in audit and '"vm.input.batch"' in audit and '"vm.input.text"' in audit
print("mcp-actions linux: the batch and each action are audited; the typed text is not in the record")

# The kill switch while 3,000 characters are being typed (24 s at VZ's pace): nothing typed 300 ms later, and the
# action after the text never runs. The itest bridge (the app's identity) ends the line twice: first right after
# the stop, then 2 s later; the second line must be empty.
before = len(typed_lines())
long = client.start("tools/call", {"name": "vm_actions", "arguments": {"vm": vm, "actions": [
    {"type": "type", "text": "x" * 3000}, {"type": "type", "text": "AFTER", "submit": True}]}})
time.sleep(1.5)
subprocess.run([cli, "mcp", "kill"], check=True, capture_output=True)
time.sleep(0.3)
bridge("vm.input.text", {"text": "\n"})
time.sleep(2)
bridge("vm.input.text", {"text": "\n"})
first, second = wait_line(before + 1), wait_line(before + 2)
assert 0 < first.count("x") < 3000 and "AFTER" not in first, first[:80]
assert second == "", f"typing went on after the kill switch: {second[:80]!r}"
assert not any("AFTER" in line for line in typed_lines())
try:
    answer = client.wait(long, timeout=10)
    assert answer.get("result", {}).get("isError") or "error" in answer, answer
except Exception as error:
    assert "Empty" not in type(error).__name__, "the stopped call was never answered"
print(f"mcp-actions linux: the kill switch stopped typing after {first.count('x')} of 3000 characters; the next action did not run")
client.close()
PY
    echo "mcp-actions linux: capture timing:"
    it_verify_log "$since"
}

scenario_windows() {
    local golden work bundle pid socket cli since status
    cli="$APP/Contents/Helpers/vmpane"
    (($(df -g "$HOME" | awk 'NR == 2 {print $4}') >= 15)) || { echo "mcp-actions: Windows needs 15 GiB free" >&2; return 77; }
    golden=$(it_golden_windows) || { status=$?; return "$status"; }
    work=$(mktemp -d /tmp/vp-ma.XXXXXX)
    export VMPANE_SUPPORT_DIR="$work/s"
    mkdir -p "$VMPANE_SUPPORT_DIR/VMs"
    bundle="$VMPANE_SUPPORT_DIR/VMs/W.vmpane"
    it_clone_bundle "$golden" "$bundle"
    trap 'set +e; [[ -n ${pid:-} ]] && kill -TERM "$pid" 2>/dev/null && it_wait_exit "$pid" 150; rm -rf "$work"; trap - RETURN; true' RETURN
    pid=$(it_start_helper "$bundle") || return 1
    socket=$(it_socket "$bundle")
    it_rpc "$socket" vm.start '{"headless": true}' >/dev/null || it_fail "vm.start failed" || return 1
    it_wait_for 180 bash -c "/usr/bin/python3 '$VMPANE_ROOT/itest/lib/rpc.py' '$socket' agent.status | jq -e .connected >/dev/null" \
        || it_fail "the agent did not connect" || return 1
    it_windows_autologon "$socket" "$work" || it_fail "no signed-in desktop after turning on automatic sign-in" || return 1
    it_wait_windows_desktop "$socket" 120 || it_fail "no Windows desktop" || return 1
    sleep 20  # first-logon animations and startup apps settle
    it_set_policy control || it_fail "cannot set the policy" || return 1
    since=$(date '+%Y-%m-%d %H:%M:%S')

    /usr/bin/python3 - "$cli" "$VMPANE_ROOT/itest/results/mcp-actions-windows-failure.png" <<'PY' || { it_fail "the MCP session failed"; return 1; }
import json, os, sys, time
sys.path.insert(0, os.path.join(os.environ["VMPANE_ROOT"], "itest/lib"))
from mcp_client import MCPClient

client = MCPClient(sys.argv[1])
vm = client.call("vm_list")["structuredContent"]["vms"][0]["id"]
def check(condition, detail):
    if not condition:  # what the screen showed, for the failure
        import base64
        image = client.call("vm_screenshot", vm=vm, max_edge=1280)["content"][0]["data"]
        open(sys.argv[2], "wb").write(base64.b64decode(image))
        raise AssertionError(f"{detail} (screen: {sys.argv[2]})")
shot = client.call("vm_screenshot", vm=vm, max_edge=1280)["structuredContent"]
w, h = shot["width"], shot["height"]
started = time.time()
# The pointer goes to a corner first; the Start menu takes a moment to open the first time.
opened = client.call("vm_actions", vm=vm, settle_ms=3000, actions=[
    {"type": "move", "x": w - 4, "y": 4}, {"type": "wait", "ms": 300}, {"type": "key", "combo": "win"}, {"type": "wait", "ms": 1500}])
elapsed = time.time() - started
structured = opened["structuredContent"]
check(all(r["ok"] for r in structured["results"]) and len(structured["results"]) == 4, opened)
verified = structured["verified"]
check(verified["status"] == "changed" and verified["changeRatio"] > 0.05, verified)
box = verified["bbox"]
check(box["width"] > w * 0.2 and box["y"] + box["height"] <= h + 1, verified)
print(f"mcp-actions windows: vm_actions opened the Start menu in one call ({elapsed:.2f} s); verified {json.dumps(verified)}")
closed = client.call("vm_key", vm=vm, combo="esc", settle_ms=3000)["structuredContent"]["verified"]
check(closed["status"] == "changed", closed)
print(f"mcp-actions windows: vm_key esc closed it; verified {json.dumps(closed)}")
client.close()
PY
    echo "mcp-actions windows: capture timing:"
    it_verify_log "$since"
}

scenario_run() {
    local status=0
    scenario_linux || return 1
    scenario_windows || status=$?
    [[ $status == 77 ]] && { echo "mcp-actions: Windows part skipped"; return 0; }
    return "$status"
}
