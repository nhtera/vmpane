"""Drives a VM's screen like a user, through its helper: screenshots read by OCR (itest/lib/ocr.swift), clicks on
text found there, keys and typing (vm.input.*). For guests without an agent yet (macOS Setup Assistant).

Usage: guest_ui.py <socket> <ocr binary> setup <user> <password>   (macOS Setup Assistant, to the desktop)
       guest_ui.py <socket> <ocr binary> install-agent <user> <password>   (VMPane Agent.pkg from the tools share)
  and for trying steps by hand: shot <png> | text | click <text> | key <name...> | type <text>
"""
import base64
import json
import os
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from helper_socket import HelperConnection  # noqa: E402

# USB HID keyboard usages.
KEYS = {"return": 0x28, "escape": 0x29, "tab": 0x2B, "space": 0x2C, "right": 0x4F, "left": 0x50, "down": 0x51,
        "up": 0x52, "cmd": 0xE3, "shift": 0xE1, "alt": 0xE2, "ctrl": 0xE0}
for i, letter in enumerate("abcdefghijklmnopqrstuvwxyz"):
    KEYS[letter] = 0x04 + i


class GuestUI:
    def __init__(self, socket_path, ocr):
        self.socket_path = socket_path
        self.ocr = ocr
        self.scale = 1.0
        self.last_png = None

    def call(self, method, params=None):
        with HelperConnection(self.socket_path) as conn:
            for request_id, (name, args) in enumerate(
                    [("helper.hello", {"proto": 1, "minProto": 1, "client": {"name": "itest", "version": "0", "kind": "cli"}}),
                     (method, params)]):
                message = {"jsonrpc": "2.0", "id": request_id, "method": name}
                if args is not None:
                    message["params"] = args
                conn.sendall((json.dumps(message) + "\n").encode())
                reply = json.loads(conn.readline())
                if "error" in reply:
                    raise RuntimeError(f"{name}: {reply['error']}")
            return reply["result"]

    def shot(self, path=None):
        result = self.call("vm.screenshot", {"maxEdge": 1600})
        self.scale = result.get("scale", 1.0)
        path = path or os.path.join(tempfile.gettempdir(), f"vp-guest-ui-{os.getpid()}.png")
        with open(path, "wb") as file:
            file.write(base64.b64decode(result["dataB64"]))
        self.last_png = path
        return path

    def texts(self):
        """The text on screen now: [{text, x, y, w, h}] in screenshot pixels."""
        out = subprocess.run([self.ocr, self.shot()], capture_output=True, text=True, check=True).stdout
        return [json.loads(line) for line in out.splitlines() if line.strip()]

    def find(self, wanted, texts=None, exact=False):
        """The first text box equal to (exact) or containing `wanted` (case-insensitive)."""
        wanted = wanted.lower()
        for box in texts if texts is not None else self.texts():
            text = box["text"].lower().strip()
            if text == wanted or (not exact and wanted in text):
                return box
        return None

    def click_at(self, x, y):
        gx, gy = x * self.scale, y * self.scale
        for buttons in (0, 1, 0):
            self.call("vm.input.pointer", {"x": gx, "y": gy, "buttons": buttons})
            time.sleep(0.08)

    def click(self, box):
        self.click_at(box["x"] + box["w"] / 2, box["y"] + box["h"] / 2)

    def key(self, *names):
        """A key, or a combination held together ("cmd", "space")."""
        usages = [KEYS[name] for name in names]
        for usage in usages:
            self.call("vm.input.key", {"usage": usage, "down": True})
            time.sleep(0.03)
        for usage in reversed(usages):
            self.call("vm.input.key", {"usage": usage, "down": False})
            time.sleep(0.03)

    def type(self, text):
        self.call("vm.input.text", {"text": text})


def has(texts, *words):
    """Whether any text box contains one of `words` (case-insensitive)."""
    return any(word.lower() in box["text"].lower() for box in texts for word in words)


def click_first(ui, texts, *names, top=True):
    """Clicks the first of `names` (exact text) on screen; among equal boxes the top one (dialogs sit above the
    footer buttons). True when one was clicked."""
    for name in names:
        boxes = [box for box in texts if box["text"].strip().lower() == name.lower()]
        if boxes:
            ui.click(min(boxes, key=lambda box: box["y"]) if top else max(boxes, key=lambda box: box["y"]))
            return True
    return False


def setup_assistant(ui, user, password, timeout=900, log=print):
    """Answers macOS Setup Assistant (15.x) until the Finder's desktop: English, set up as new, no Apple Account,
    no location, analytics or Screen Time, the account `user`. Also the screens shown after the first login.
    Raises with the screen's text when a screen does not change."""
    deadline = time.time() + timeout
    last, repeats = None, 0
    while time.time() < deadline:
        texts = ui.texts()
        words = [box["text"] for box in texts]
        title = " | ".join(words[:6])
        menu_bar = {box["text"] for box in texts if box["y"] < 40}
        if {"Window", "Help"} <= menu_bar and not has(texts, "Continue", "Set Up Later", "Not Now"):
            return  # an app's menu bar, no setup screen: the desktop
        repeats = repeats + 1 if title == last else 0
        last = title
        if repeats >= 6:
            raise RuntimeError("Setup Assistant is stuck on: " + " | ".join(words))
        if repeats % 2:  # an animation or a slow screen: look again before acting twice
            time.sleep(3)
            continue
        log("setup: " + " | ".join(words[:4]))
        if has(texts, "English (UK)") and not has(texts, "Written and Spoken"):  # the language list
            click_first(ui, texts, "English")
            time.sleep(4)
            ui.key("return")
        elif has(texts, "Transfer Your Data", "Migration Assistant"):
            click_first(ui, texts, "Set up as new")
            time.sleep(1)
            click_first(ui, texts, "Continue", "Not Now", top=False)
        elif has(texts, "Create a Mac Account", "Create a Computer Account"):
            ui.type(user)
            ui.key("tab")
            ui.key("cmd", "a")
            ui.type(user)
            ui.key("tab")
            ui.type(password)
            ui.key("tab")
            ui.type(password)
            time.sleep(1)
            click_first(ui, texts, "Continue", top=False)
        elif has(texts, "Terms and Conditions") and not has(texts, "I have read and agree"):
            click_first(ui, texts, "Agree", top=False)
        elif has(texts, "I have read and agree"):
            click_first(ui, texts, "Agree")
        elif has(texts, "Analytics") and has(texts, "Share Mac Analytics"):
            box = next(box for box in texts if "Share Mac Analytics" in box["text"])
            ui.click(box)  # unchecked: test VMs send Apple nothing
            time.sleep(1)
            click_first(ui, texts, "Continue", top=False)
        elif has(texts, "Are you sure you want to skip"):
            click_first(ui, texts, "Skip")
        elif has(texts, "Update Mac Automatically"):
            click_first(ui, texts, "Only Download Automatically")
        elif len(texts) <= 4 and not has(texts, "Continue"):  # the greeting ("hello" in turns of languages)
            ui.key("return")
        elif not click_first(ui, texts, "Don't Use", "Not Now", "Set Up Later", "Skip", "Continue"):
            ui.key("return")
        time.sleep(4)
    raise RuntimeError("Setup Assistant did not finish in time")


def wait_text(ui, wanted, timeout=60):
    """Waits until a text box contains `wanted`; returns the screen's text boxes."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        texts = ui.texts()
        if has(texts, wanted):
            return texts
        time.sleep(2)
    raise RuntimeError(f"{wanted!r} did not appear; the screen shows: " + " | ".join(box["text"] for box in ui.texts()))


def install_agent(ui, user, password, pkg="/Volumes/My Shared Files/vmpane-tools/VMPane Agent.pkg"):
    """As the user would: Terminal (from Spotlight), the agent package with sudo, then auto-login (so the agent's
    session part runs after each start) and no sleep or screen saver."""
    ui.key("cmd", "space")
    time.sleep(2)
    ui.type("Terminal")
    time.sleep(2)
    ui.key("return")
    wait_text(ui, f"{user}@")  # the shell prompt
    # The test account's password (not a secret: test VMs only) goes to sysadminctl for the auto-login.
    ui.type(f"clear; sudo sh -c 'installer -pkg \"{pkg}\" -target / && sysadminctl -autologin set -userName {user}"
            f" -password {password} && pmset -a sleep 0 displaysleep 0 disksleep 0'"
            " && defaults -currentHost write com.apple.screensaver idleTime 0 && echo VMPANE-SETUP-OK\n")
    wait_text(ui, "Password:")
    ui.type(password + "\n")
    wait_text(ui, "VMPANE-SETUP-OK", timeout=180)


def main():
    ui = GuestUI(sys.argv[1], sys.argv[2])
    command, args = sys.argv[3], sys.argv[4:]
    if command == "shot":
        ui.shot(args[0])
    elif command == "text":
        for box in ui.texts():
            print(json.dumps(box))
    elif command == "click":
        box = ui.find(" ".join(args))
        if not box:
            sys.exit(f"not on screen: {' '.join(args)}")
        ui.click(box)
    elif command == "key":
        ui.key(*args)
    elif command == "type":
        ui.type(" ".join(args))
    elif command == "setup":  # setup <user> <password>
        setup_assistant(ui, args[0], args[1])
    elif command == "install-agent":  # install-agent <user> <password>
        install_agent(ui, args[0], args[1])


if __name__ == "__main__":
    main()
