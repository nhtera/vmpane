# Reading a macOS guest's screen through `vmpane mcp` (agent edge, Phase 02), on the golden macOS bundle with a
# user and the guest tools (build-golden-macos-user.sh), driven only through VMPane's own tools:
#   1. Without the Accessibility grant: source elements says how to grant it, auto reads the text (a Finder window:
#      its sidebar), and the first refusal brings up macOS's prompt for the agent.
#   2. The grant, as a person gives it: "Open System Settings" in that prompt, the agent's switch, the password.
#   3. With it: elements lists the Finder window's controls (the sidebar's Downloads), and vm_click on that id
#      opens Downloads.
# A full-resolution screenshot of Finder lands in itest/results/screen-read-macos.png (an OCR fixture).
# Sourced by scripts/itest.sh with $APP set.

source "$VMPANE_ROOT/itest/lib/common.sh"
IT_SCENARIO=screen-read-macos

scenario_run() {
    local golden work bundle pid socket cli status
    cli="$APP/Contents/Helpers/vmpane"
    it_require_unlocked || return 77
    golden=$(it_golden_macos_user) || { status=$?; return "$status"; }
    work=$(mktemp -d /tmp/vp-srm.XXXXXX)
    export VMPANE_SUPPORT_DIR="$work/s"
    mkdir -p "$VMPANE_SUPPORT_DIR/VMs"
    bundle="$VMPANE_SUPPORT_DIR/VMs/M.vmpane"
    it_clone_bundle "$golden" "$bundle"
    trap 'set +e; [[ -n ${pid:-} ]] && kill -9 "$pid" 2>/dev/null && it_wait_exit "$pid" 10; rm -rf "$work"; trap - RETURN; true' RETURN
    pid=$(it_start_helper "$bundle") || return 1
    socket=$(it_socket "$bundle")
    it_rpc "$socket" vm.start '{"headless": true}' >/dev/null || it_fail "vm.start failed" || return 1
    it_wait_for 240 bash -c "/usr/bin/python3 '$VMPANE_ROOT/itest/lib/rpc.py' '$socket' agent.status 2>/dev/null \
        | jq -e '.connected and .session' >/dev/null" || it_fail "the agent's user session did not connect" || return 1
    sleep 15  # the desktop and its first-login extras settle
    it_set_policy control || it_fail "cannot set the policy" || return 1
    # A Finder window in front: the user's home.
    /usr/bin/python3 "$VMPANE_ROOT/itest/lib/agent_exec.py" "$socket" --user 'open ~' >/dev/null || it_fail "open failed" || return 1
    sleep 3

    /usr/bin/python3 - "$cli" "$VMPANE_ROOT/itest/results/screen-read-macos" "$socket" "$IT_MACOS_PASSWORD" <<'PY' || { it_fail "the MCP session failed"; return 1; }
import base64, os, subprocess, sys, time
sys.path.insert(0, os.path.join(os.environ["VMPANE_ROOT"], "itest/lib"))
from mcp_client import MCPClient

cli, out, socket, password = sys.argv[1:5]
client = MCPClient(cli)
vm = client.call("vm_list")["structuredContent"]["vms"][0]["id"]
def save(name):
    shot = client.call("vm_screenshot", vm=vm, max_edge=8192)["content"][0]["data"]
    open(f"{out}-{name}.png", "wb").write(base64.b64decode(shot))
def read(source, tolerate=False):
    result = client.call("vm_read_screen", vm=vm, source=source)
    assert tolerate or not result.get("isError"), result
    return result
def items(result, source):
    return result["structuredContent"]["untrusted_guest_text"].get(source, [])
def label(item):
    return (item.get("text") or item.get("name") or "").strip()
def find(source, wanted, timeout=20):
    deadline = time.time() + timeout
    while True:
        result = read(source, tolerate=time.time() < deadline)
        found = [] if result.get("isError") else [item for item in items(result, source) if label(item) == wanted]
        if found or time.time() > deadline:
            return found, result
        time.sleep(1)

# 1. No grant yet.
refused = client.call("vm_read_screen", vm=vm, source="elements")
assert refused.get("isError") and "allow vmpane-agent" in refused["content"][0]["text"], refused
auto = read("auto")
header = auto["content"][0]["text"].splitlines()[0]
assert auto["structuredContent"]["source"] == "ocr" and "allow vmpane-agent" in header, header
texts = [label(item) for item in items(auto, "ocr")]
assert any("Downloads" in t for t in texts) and any("Applications" in t for t in texts), texts
save("finder")
print(f"screen-read macos: without the grant, elements asks for it and auto read {len(texts)} lines of Finder")

# 2. The grant: macOS's prompt, then the agent's switch in System Settings and the password.
button, result = find("ocr", "Open System Settings")
if not button:
    save("failure")
    raise AssertionError(f"no Accessibility prompt: {[label(i) for i in items(result, 'ocr')]}")
client.call("vm_click", vm=vm, element=button[0]["id"], settle_ms=3000)
row, result = find("ocr", "vmpane-agent")
if not row:
    save("failure")
    raise AssertionError(f"System Settings does not list the agent: {[label(i) for i in items(result, 'ocr')]}")
import png_pixels
shot = client.call("vm_screenshot", vm=vm, max_edge=8192)
png = base64.b64decode(shot["content"][0]["data"])
open(f"{out}-settings.png", "wb").write(png)
_, _, pixels = png_pixels.read(png)
# The switch has no text: it is the first thing right of the agent's name that stands out from the row (a
# screenshot as large as the guest's display, so its pixels are the read's pixels at the read's scale).
scale = result["structuredContent"]["screen"]["scale"] / shot["structuredContent"]["scale"]
box = [v * scale for v in row[0]["rect"]]
y = int(box[1] + box[3] / 2)
x = png_pixels.switch_right_of(pixels, y, int(box[0] + box[2]))
assert x, "no switch right of vmpane-agent"
client.call("vm_click", vm=vm, x=x, y=y, settle_ms=2000)  # that screenshot set the scale: its pixels
prompt, result = find("ocr", "Modify Settings", timeout=10)
if not prompt:
    save("failure")
    raise AssertionError(f"no password prompt after the switch: {[label(i) for i in items(result, 'ocr')]}")
client.call("vm_type", vm=vm, text=password, settle_ms=500)
# Return in the password field does not always submit the sheet: its button does.
button, result = find("ocr", "Modify Settings", timeout=5)
if button:
    client.call("vm_click", vm=vm, element=button[0]["id"], settle_ms=2000)
gone, result = find("ocr", "Modify Settings", timeout=1)
save("granted")
print("screen-read macos: Accessibility granted to the agent through System Settings")

# 3. With the grant: Finder's controls.
subprocess.run(["/usr/bin/python3", os.path.join(os.environ["VMPANE_ROOT"], "itest/lib/agent_exec.py"), socket, "--user",
                "open ~"], check=True, capture_output=True)
time.sleep(3)
downloads, result = find("elements", "Downloads")
if not downloads:
    save("failure")
    raise AssertionError(f"Finder's controls have no Downloads: {result['content'][0]['text'][:1500]}")
# The sidebar's (the home folder shows a Downloads folder too): the leftmost.
sidebar = min(downloads, key=lambda item: item["rect"][0])
windows = [label(item) for item in items(result, "elements") if item.get("role") == "window"]
assert windows and "Downloads" not in windows, windows
print(f"screen-read macos: {len(items(result, 'elements'))} controls; {sidebar['id']} {sidebar['role']} at {sidebar['rect']}")
clicked = client.call("vm_click", vm=vm, element=sidebar["id"], settle_ms=2000)
assert clicked["structuredContent"]["verified"]["status"] == "changed", clicked
deadline = time.time() + 10
while True:
    windows = [label(item) for item in items(read("elements"), "elements") if item.get("role") == "window"]
    if "Downloads" in windows or time.time() > deadline:
        break
    time.sleep(1)
assert "Downloads" in windows, f"the Finder window is still {windows}"
downloads = [sidebar]
save("downloads")
print(f"screen-read macos: vm_click on {downloads[0]['id']} opened Downloads")
client.close()
PY
}
