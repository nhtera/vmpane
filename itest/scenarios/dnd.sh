# Files dropped on a Linux VZ guest (Phase 09): vm.files.drop (what the VM window's drop target calls) copies 3
# files and a folder (with a nested file and a symlink) into the logged-in user's Desktop/VMPane Drops; the
# copies match by SHA-256, belong to the user, keep the folder structure, and the symlink is skipped.
# Needs an app built with the Linux guest tools. Sourced by scripts/itest.sh with $APP set.

source "$VMPANE_ROOT/itest/lib/common.sh"
IT_SCENARIO=dnd

it_agent_exec() { /usr/bin/python3 "$VMPANE_ROOT/itest/lib/agent_exec.py" "$socket" "$@"; }
it_agent_connected() { [[ $(it_rpc "$socket" agent.status | jq -r .connected) == true ]]; }

scenario_run() {
    local work bundle pid socket src out guest name sum owner
    [[ -f "$APP/Contents/Resources/GuestTools/linux/SHA256SUMS" ]] \
        || { echo "dnd: the app has no Linux guest tools (guest-tools/build-linux.sh, then rebuild)" >&2; return 77; }
    it_boot_linux_clone || return 1
    trap 'set +e; [[ -n ${pid:-} ]] && kill -9 "$pid" 2>/dev/null; rm -rf "$work"; true' RETURN
    it_rpc "$socket" vm.input.text '{"text": "VMPANE-INSTALL-AGENT\n"}' >/dev/null
    it_wait_for 60 grep -qa 'VMPANE-AGENT-INSTALLED rc=0' "$bundle/logs/serial.log" || it_fail "the agent did not install" || return 1
    it_wait_for 30 it_agent_connected || it_fail "the agent did not connect" || return 1
    # A logged-in user (auto-login on tty2), whose session helper the drop runs as.
    it_agent_exec 'mkdir -p /etc/systemd/system/getty@tty2.service.d && printf "[Service]\nExecStart=\nExecStart=-/sbin/agetty --autologin ubuntu --noclear %%I \$TERM\n" >/etc/systemd/system/getty@tty2.service.d/autologin.conf && systemctl daemon-reload && systemctl restart getty@tty2 && chvt 2' >/dev/null \
        || it_fail "cannot log a user in" || return 1
    it_wait_for 60 bash -c "[[ \$(/usr/bin/python3 '$VMPANE_ROOT/itest/lib/rpc.py' '$socket' agent.status | jq -r .session) == true ]]" \
        || it_fail "no user session" || return 1

    src="$work/drop"
    mkdir -p "$src/Album/2026"
    for name in one.txt "two words.bin" "três.dat"; do head -c $((RANDOM * 64)) /dev/urandom >"$src/$name"; done
    head -c 3000000 /dev/urandom >"$src/Album/2026/photo.jpg"
    ln -s /etc/passwd "$src/Album/link"
    out=$(it_rpc "$socket" vm.files.drop "$(jq -nc --arg s "$src" '{paths: [$s + "/one.txt", $s + "/two words.bin", $s + "/três.dat", $s + "/Album"]}')") \
        || it_fail "vm.files.drop failed: $out" || return 1
    guest=$(jq -r .guestPath <<<"$out")
    [[ $guest == /home/ubuntu/Desktop/VMPane\ Drops/* ]] || it_fail "dropped into '$guest'" || return 1
    [[ $(jq -r .files <<<"$out") == 4 && $(jq -c .skipped <<<"$out") == '["Album/link"]' ]] || it_fail "unexpected result: $out" || return 1
    for name in one.txt "two words.bin" "três.dat" Album/2026/photo.jpg; do
        sum=$(shasum -a 256 "$src/$name" | cut -d' ' -f1)
        [[ $(it_agent_exec "sha256sum \"$guest/$name\"" | cut -d' ' -f1) == "$sum" ]] || it_fail "$name differs in the guest" || return 1
    done
    owner=$(it_agent_exec "stat -c %U \"$guest/Album/2026/photo.jpg\" \"$guest\" | sort -u")
    [[ $owner == ubuntu ]] || it_fail "the dropped files belong to '$owner'" || return 1
    if it_agent_exec "test -e \"$guest/Album/link\""; then it_fail "the symlink was copied"; return 1; fi
    echo "dnd: 3 files + a folder dropped into $guest: SHA-256 match, owned by ubuntu, symlink skipped (revealed: $(jq -r .revealed <<<"$out"))"

    # A cancelled drop stops and leaves nothing behind.
    head -c 1073741824 /dev/zero >"$src/big.bin"
    # Drop and cancel on one connection (only the connection that started a drop may cancel it).
    /usr/bin/python3 - "$socket" "$src/big.bin" >"$work/cancelled.json" 2>&1 <<'PY' || { it_fail "cancel: $(cat "$work/cancelled.json")"; return 1; }
import json, os, sys, time
sys.path.insert(0, os.path.join(os.environ["VMPANE_ROOT"], "itest/lib"))
from helper_socket import HelperConnection
sock = HelperConnection(sys.argv[1])
reader = sock
def send(i, method, params):
    sock.sendall((json.dumps({"jsonrpc": "2.0", "id": i, "method": method, "params": params}) + "\n").encode())
send(0, "helper.hello", {"proto": 1, "minProto": 1, "client": {"name": "itest", "version": "0", "kind": "cli"}})
json.loads(reader.readline())
send(1, "vm.files.drop", {"paths": [sys.argv[2]]})
time.sleep(1)
send(2, "vm.files.cancel", {})
answers = {}
while len(answers) < 2:
    message = json.loads(reader.readline())
    if "id" in message:
        answers[message["id"]] = message
print(json.dumps(answers))
assert "result" in answers[2], answers[2]
assert answers[1].get("error", {}).get("message") == "cancelled", answers[1]
PY
    [[ $(it_agent_exec 'ls "/home/ubuntu/Desktop/VMPane Drops" | wc -l') == 1 ]] \
        || it_fail "the cancelled drop left a folder: $(it_agent_exec 'ls "/home/ubuntu/Desktop/VMPane Drops"')" || return 1
    echo "dnd: a cancelled drop stops and its folder is removed"
}
