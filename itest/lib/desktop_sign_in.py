"""Desktop apps and agent sign-in through `vmpane mcp` (desktop-sign-in.sh): one phase per call.
  launch <cli> <os>             vm_exec desktop opens the guest's test app; its name shows on the screen
  sign-in <cli> <expect>        vm_sign_in; <expect>: signed_in or already_signed_in
  lock <cli>                    the macOS lock shortcut (ctrl+cmd+q)
Every reply is appended to $DSI_TRANSCRIPT (the MCP transcript checked for the password afterwards)."""
import json, os, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mcp_client import MCPClient

APPS = {
    # A classic Win32 program (Store apps such as Notepad are started by Windows, not by the command).
    "windows": (["charmap.exe"], "Character Map"),
    "macos": (["/System/Applications/TextEdit.app"], "TextEdit"),
}

phase, cli = sys.argv[1], sys.argv[2]
client = MCPClient(cli)
vm = client.call("vm_list")["structuredContent"]["vms"][0]["id"]

def record(result):
    with open(os.environ["DSI_TRANSCRIPT"], "a") as out:
        out.write(json.dumps(result) + "\n")
    return result

def screen_has(text, timeout=30):
    deadline = time.time() + timeout
    while True:
        read = record(client.call("vm_read_screen", vm=vm, source="ocr"))
        lines = [item["text"] for item in read.get("structuredContent", {}).get("untrusted_guest_text", {}).get("ocr", [])]
        if any(text in line for line in lines) or time.time() > deadline:
            return any(text in line for line in lines), lines
        time.sleep(1)

if phase == "launch":
    argv, title = APPS[sys.argv[3]]
    started = record(client.call("vm_exec", vm=vm, argv=argv, desktop=True))
    assert not started.get("isError"), started
    structured = started["structuredContent"]
    assert structured["launched"] is True and structured["pid"] > 0, structured
    shown, lines = screen_has(title)
    assert shown, f"{title} is not on the screen: {lines[-20:]}"
    print(f"desktop-sign-in: vm_exec desktop opened {title} (pid {structured['pid']})")
elif phase == "lock":
    record(client.call("vm_key", vm=vm, combo="ctrl+cmd+q", settle_ms=2000))
elif phase == "sign-in":
    expect = sys.argv[3]
    started = time.time()
    result = record(client.call("vm_sign_in", vm=vm))
    assert not result.get("isError"), result
    status = result["structuredContent"]["verified"]["status"]
    assert status == expect, result
    print(f"desktop-sign-in: vm_sign_in {status} in {time.time() - started:.1f} s")
client.close()
