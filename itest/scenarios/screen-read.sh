# Reading the screen through `vmpane mcp` (agent edge, Phase 02), in real guests:
# Linux (VZ): at Look only, vm_read_screen (ocr, no screenshot first) finds text typed on the console, takes no
# Before-agent snapshot, and source elements says to update the guest tools; vm_click is refused at that level.
# Windows (QEMU, after automatic sign-in): Settings opened by vm_actions; vm_read_screen with no screenshot first;
# its text (ocr) has "Bluetooth & devices", and with the agent under test (VMPANE_ITEST_WINDOWS_AGENT, else
# agent/target/aarch64-pc-windows-msvc/release/vmpane-agent.exe when built) its controls (elements) list it as a
# listitem; vm_click on that id opens the page. Full-resolution screenshots land in itest/results/screen-read-*.png
# (OCR fixtures). Skips Windows without the golden or 15 GiB free.
# Sourced by scripts/itest.sh with $APP set.

source "$VMPANE_ROOT/itest/lib/common.sh"
IT_SCENARIO=screen-read

it_ocr_log() {
    /usr/bin/log show --info --start "$1" --predicate 'eventMessage BEGINSWITH "screen read: "' --style compact 2>/dev/null \
        | grep -o 'screen read: .*' | tail -4
}

scenario_linux() {
    local work bundle pid socket cli since
    cli="$APP/Contents/Helpers/vmpane"
    since=$(date '+%Y-%m-%d %H:%M:%S')
    it_boot_linux_clone || return 1
    trap 'set +e; [[ -n ${pid:-} ]] && kill -9 "$pid" 2>/dev/null; rm -rf "$work"; trap - RETURN; true' RETURN
    # Typed by the itest bridge (the app's identity): no agent session yet.
    sleep 8  # cloud-init's last lines print on the console a few seconds after the ready marker
    # Two rows above the bottom: the very last row, against the screen's edge, reads poorly.
    it_rpc "$socket" vm.input.text '{"text": "echo VMPANE OCR CHECK 4271\n\n"}' >/dev/null || it_fail "typing failed" || return 1
    sleep 1
    it_set_policy observe || it_fail "cannot set the policy" || return 1

    /usr/bin/python3 - "$cli" "$VMPANE_ROOT/itest/results/screen-read-linux.png" <<'PY' || { it_fail "the MCP session failed"; return 1; }
import base64, os, sys, time
sys.path.insert(0, os.path.join(os.environ["VMPANE_ROOT"], "itest/lib"))
from mcp_client import MCPClient

client = MCPClient(sys.argv[1])
vm = client.call("vm_list")["structuredContent"]["vms"][0]["id"]
started = time.time()
read = client.call("vm_read_screen", vm=vm)
elapsed = time.time() - started
assert not read.get("isError"), read
structured = read["structuredContent"]
items = structured["untrusted_guest_text"]["ocr"]
assert structured["source"] == "ocr" and structured["screen"]["scale"] >= 1, structured
# Console bitmap text is read word by word at times, and a letter can come out wrong ("UMPANE"): the marker is
# found when 3 of its 4 words are on one row.
words = {"VMPANE", "OCR", "CHECK", "4271"}
rows = {}
for item in items:
    middle = item["rect"][1] + item["rect"][3] / 2
    key = next((row for row in rows if abs(row - middle) < 6), middle)
    rows.setdefault(key, []).append(item)
found = []
for row in rows.values():
    if len(words & set(" ".join(item["text"] for item in row).upper().split())) >= 3:
        found = sorted(row, key=lambda item: item["rect"][0])
if not found:
    shot = client.call("vm_screenshot", vm=vm, max_edge=8192)["content"][0]["data"]
    open(sys.argv[2].replace(".png", "-failure.png"), "wb").write(base64.b64decode(shot))
    raise AssertionError([item["text"] for item in items][-8:])
assert found[0]["id"].startswith("t"), found
assert "untrusted_guest_text" in read["content"][0]["text"]
print(f"mcp-read linux: ocr at Look only in {elapsed:.2f} s, {len(items)} lines; the typed text: {[i['text'] for i in found]} ({found[0]['id']} at {found[0]['rect']})")

elements = client.call("vm_read_screen", vm=vm, source="elements")
assert elements.get("isError") and "update them" in elements["content"][0]["text"], elements
refused = client.call("vm_click", vm=vm, element=found[0]["id"])
assert refused.get("isError") and "Refused" in refused["content"][0]["text"], refused
snapshots = client.call("vm_snapshot_list", vm=vm)["structuredContent"]["snapshots"]
assert not [s for s in snapshots if s["origin"] == "agentSession"], snapshots
shot = client.call("vm_screenshot", vm=vm, max_edge=8192)["content"][0]["data"]
open(sys.argv[2], "wb").write(base64.b64decode(shot))
print("mcp-read linux: elements asks for newer guest tools; a click is refused at Look only; no Before-agent snapshot")
client.close()
PY
    it_ocr_log "$since"
}

# What UI Automation shows the signed-in user of the Windows guest (a failure's diagnosis): the foreground window
# and its first controls, read by PowerShell as that user.
it_uia_diagnose() {
    cat >"$work/uia.ps1" <<'PS1'
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
Add-Type 'using System; using System.Runtime.InteropServices; public class W { [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow(); }'
$h = [W]::GetForegroundWindow(); "foreground $h"
$e = [System.Windows.Automation.AutomationElement]::FromHandle($h); "window: $($e.Current.Name) $($e.Current.ClassName)"
$all = $e.FindAll([System.Windows.Automation.TreeScope]::Subtree, [System.Windows.Automation.Automation]::ControlViewCondition)
"count $($all.Count)"
$all | Select-Object -First 12 | ForEach-Object { "$($_.Current.ControlType.ProgrammaticName) | $($_.Current.Name) | $($_.Current.BoundingRectangle) | off=$($_.Current.IsOffscreen)" }
PS1
    it_rpc "$socket" agent.file.push "$(jq -n --arg h "$work/uia.ps1" '{hostPath: $h, guestPath: "C:\\Users\\Public\\uia.ps1"}')" >/dev/null
    /usr/bin/python3 "$VMPANE_ROOT/itest/lib/agent_exec.py" "$socket" --user \
        'powershell -NoProfile -ExecutionPolicy Bypass -File C:\Users\Public\uia.ps1' | tr -d '\r' | head -20
    echo "screen-read: the helper's own read:"
    it_rpc "$socket" vm.screen.read '{"source": "elements"}' | head -c 600
    echo
}

scenario_windows() {
    local golden work bundle pid socket cli since status
    cli="$APP/Contents/Helpers/vmpane"
    (($(df -g "$HOME" | awk 'NR == 2 {print $4}') >= 15)) || { echo "screen-read: Windows needs 15 GiB free" >&2; return 77; }
    golden=$(it_golden_windows) || { status=$?; return "$status"; }
    work=$(mktemp -d /tmp/vp-sr.XXXXXX)
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
    local agent=${VMPANE_ITEST_WINDOWS_AGENT:-$VMPANE_ROOT/agent/target/aarch64-pc-windows-msvc/release/vmpane-agent.exe}
    [[ -f $agent ]] || agent=""
    it_windows_autologon "$socket" "$work" "$agent" || it_fail "no signed-in desktop after turning on automatic sign-in" || return 1
    if [[ -n $agent ]]; then
        it_rpc "$socket" agent.status | jq -e '.caps | index("screen")' >/dev/null || it_fail "the agent under test has no screen cap" || return 1
        echo "screen-read: the agent under test: $agent"
    fi
    it_wait_windows_desktop "$socket" 120 || it_fail "no Windows desktop" || return 1
    sleep 20  # first-logon animations and startup apps settle
    it_set_policy control || it_fail "cannot set the policy" || return 1
    since=$(date '+%Y-%m-%d %H:%M:%S')

    /usr/bin/python3 - "$cli" "$VMPANE_ROOT/itest/results/screen-read-windows" "${agent:+elements}" <<'PY' || { it_uia_diagnose; it_fail "the MCP session failed"; return 1; }
import base64, os, sys, time
sys.path.insert(0, os.path.join(os.environ["VMPANE_ROOT"], "itest/lib"))
from mcp_client import MCPClient

cli, out, controls = sys.argv[1], sys.argv[2], sys.argv[3] == "elements"
setup = MCPClient(cli)
vm = setup.call("vm_list")["structuredContent"]["vms"][0]["id"]
setup.call("vm_actions", vm=vm, actions=[{"type": "key", "combo": "win+i"}, {"type": "wait", "ms": 8000}])
setup.close()

# A new session: no screenshot has set the scale.
client = MCPClient(cli)
def save(name):
    shot = client.call("vm_screenshot", vm=vm, max_edge=8192)["content"][0]["data"]
    open(f"{out}-{name}.png", "wb").write(base64.b64decode(shot))
def items(read, source):
    return read["structuredContent"]["untrusted_guest_text"].get(source, [])
def label(item):
    return (item.get("text") or item.get("name") or "").strip()
started = time.time()
read = client.call("vm_read_screen", vm=vm, source="both" if controls else "ocr")
elapsed = time.time() - started
assert not read.get("isError"), read
text = items(read, "ocr")
if not any(label(item) == "Bluetooth & devices" for item in text):
    save("failure")
    raise AssertionError(f"no 'Bluetooth & devices' in {[label(item) for item in text]}")
print(f"mcp-read windows: Settings read in {elapsed:.2f} s ({len(text)} lines); scale {read['structuredContent']['screen']['scale']}")
save("settings")
if controls:
    found = [item for item in items(read, "elements") if label(item) == "Bluetooth & devices"]
    assert found and found[0]["role"] == "listitem" and found[0]["id"].startswith("e"), (
        read["content"][0]["text"].splitlines()[0], [(i["role"], label(i)) for i in items(read, "elements")][:30])
    target = found[0]
    print(f"mcp-read windows: {len(items(read, 'elements'))} controls; {target['id']} {target['role']} at {target['rect']}")
else:
    target = [item for item in text if label(item) == "Bluetooth & devices"][0]
for attempt in range(2):  # a Settings window just opened can miss its first click
    clicked = client.call("vm_click", vm=vm, element=target["id"], settle_ms=3000)
    assert not clicked.get("isError"), clicked
    time.sleep(1)
    after = [label(item) for item in items(client.call("vm_read_screen", vm=vm, source="ocr"), "ocr")]
    if any("Add device" in line for line in after):
        break
    reread = client.call("vm_read_screen", vm=vm, source="elements" if controls else "ocr")
    target = [item for item in items(reread, "elements" if controls else "ocr") if label(item) == "Bluetooth & devices"][0]
else:
    save("failure")
    raise AssertionError(f"the Bluetooth & devices page did not show: {after}")
save("bluetooth")
print(f"mcp-read windows: vm_click on {target['id']} opened Bluetooth & devices (attempt {attempt + 1})")
client.close()
PY
    it_ocr_log "$since"
}

scenario_run() {
    local status=0
    scenario_linux || return 1
    scenario_windows || status=$?
    [[ $status == 77 ]] && { echo "screen-read: Windows part skipped"; return 0; }
    return "$status"
}
