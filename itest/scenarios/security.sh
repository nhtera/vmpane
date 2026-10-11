# Control-socket hardening with the real helper binary (no guest needed): file and socket permissions, another
# uid refused, an unsigned client treated as an agent (refused at policy off, audited), malformed and oversized
# input and a connection flood dropping only the offending connections, the helper alive throughout.
# Sourced by scripts/itest.sh with $APP set. Uses a throwaway support directory, never the user's library.

source "$VMPANE_ROOT/itest/lib/common.sh"
IT_SCENARIO=security

# Octal permission bits of a path.
it_mode() { stat -f %Lp "$1"; }

scenario_run() {
    local helper="$APP/Contents/Helpers/VMPaneVM.app/Contents/MacOS/VMPaneVM"
    local work
    work=$(mktemp -d /tmp/vp-it.XXXXXX)  # short: socket paths are limited to 104 bytes
    export VMPANE_SUPPORT_DIR="$work/s"
    local bundle="$VMPANE_SUPPORT_DIR/VMs/T.vmpane"
    mkdir -p "$VMPANE_SUPPORT_DIR/VMs"
    chmod 700 "$VMPANE_SUPPORT_DIR"
    it_create_bundle "$bundle"
    local sid run="$VMPANE_SUPPORT_DIR/run"
    sid=$(it_sid "$bundle")
    local socket="$run/$sid.sock" pid
    trap 'set +e
          for f in "$run"/*.children; do [[ -f $f ]] && jq -r .process.pid "$f" | xargs kill -9 2>/dev/null; done
          [[ -n ${pid:-} ]] && kill -9 "$pid" 2>/dev/null
          rm -rf "$work"
          true' RETURN

    VMPANE_TEST_DUMMY_CHILD=1 "$helper" --vm "$bundle" --headless &
    pid=$!
    it_wait_for 10 test -S "$socket" || it_fail "no socket after 10 s" || return 1
    # A policy change through the app's path makes the policy key; then back to off.
    local level
    for level in observe off; do
        it_rpc "$socket" vm.settings.apply "{\"patch\": {\"mcp\": {\"policy\": \"$level\"}}}" >/dev/null || it_fail "settings apply failed" || return 1
    done

    # 1. Permissions: private folders, owner-only sockets and files.
    local path want
    for path in "$VMPANE_SUPPORT_DIR:700" "$run:700" "$socket:600" "$bundle/config.json:600" "$VMPANE_SUPPORT_DIR/policy.key:600"; do
        want=${path##*:}
        path=${path%:*}
        [[ -e $path ]] || it_fail "$path is missing" || return 1
        [[ $(it_mode "$path") == "$want" ]] || it_fail "$path is $(it_mode "$path"), expected $want" || return 1
    done
    echo "security: support and run folders 0700; socket, config and policy key 0600"

    # 2. Another uid is refused (needs passwordless sudo; the 0700 run folder already keeps it out).
    if sudo -n -u nobody true 2>/dev/null; then
        sudo -n -u nobody /usr/bin/python3 - "$socket" <<'EOF' && it_fail "another uid reached the socket" && return 1
import socket, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
try:
    s.connect(sys.argv[1]); s.sendall(b'{"jsonrpc":"2.0","id":1,"method":"vm.info"}\n'); sys.exit(0 if s.recv(100) else 1)
except OSError:
    sys.exit(1)
EOF
        echo "security: another uid is refused"
    else
        echo "security: another uid not tried (no passwordless sudo); the run folder is 0700"
    fi

    # 3. A client that is not VMPane's (plain python, no bridge) is an agent: at policy off it is refused, and
    # the refusal is audited. Then malformed input and floods: each bad connection is dropped, the helper lives.
    /usr/bin/python3 - "$socket" <<'EOF' || it_fail "raw client checks failed" || return 1
import json, socket, sys, time
path = sys.argv[1]

def conn():
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect(path)
    s.settimeout(10)
    return s

def ask(s, payload):
    s.sendall(payload)
    data = b""
    while not data.endswith(b"\n"):
        chunk = s.recv(65536)
        if not chunk:
            return None
        data += chunk
    return json.loads(data)

def closed(s):
    try:
        while True:
            chunk = s.recv(65536)
            if not chunk:
                return True
    except (ConnectionResetError, BrokenPipeError):
        return True
    except socket.timeout:
        return False

s = conn()
answer = ask(s, b'{"jsonrpc":"2.0","id":1,"method":"vm.info"}\n')
assert answer and answer.get("error", {}).get("code") == -32012, f"an unsigned client at off got {answer}"
answer = ask(s, b'{"jsonrpc":"2.0","id":2,"method":"vm.settings.apply","params":{"patch":{"mcp":{"policy":"admin"}}}}\n')
assert answer and "error" in answer, f"an unsigned client changed the policy: {answer}"
s.close()
print("security: an unsigned client is an agent (refused at off, cannot raise the level)")

s = conn()
answer = ask(s, b'this is not json\n')
assert answer is None or answer.get("error", {}).get("code") == -32700, f"garbage got {answer}"
s.close()
s = conn()
answer = ask(s, b'\xff\xfe{"jsonrpc":"2.0","id":1,"method":"vm.info"}\n')
assert answer is None or "error" in answer, f"invalid UTF-8 got {answer}"
s.close()
s = conn()
answer = ask(s, b'{"jsonrpc":"2.0","id":1,"method":"vm.info","params":' + b"[" * 100000 + b"]" * 100000 + b"}\n")
assert answer is None or "error" in answer, f"deep nesting got {answer}"
s.close()
s = conn()
try:
    s.sendall(b'{"jsonrpc":"2.0","id":1,"method":"vm.info","params":"' + b"A" * (3 << 20))
except (BrokenPipeError, ConnectionResetError):
    pass
assert closed(s), "a line over 1 MiB did not close the connection"
s.close()
print("security: garbage, invalid UTF-8, deep nesting and a 3 MiB line are refused or dropped")

many, deadline = [], time.time() + 15
while len(many) < 300 and time.time() < deadline:
    try:
        many.append(conn())
    except OSError:
        time.sleep(0.01)  # the listen backlog is full: let the helper accept
time.sleep(1)
alive = 0
for c in many:
    c.setblocking(False)
    try:
        alive += c.recv(1) != b""
    except BlockingIOError:
        alive += 1  # open, nothing to read
    except OSError:
        pass
for c in many:
    c.close()
assert alive <= 128, f"{alive} connections kept open (cap 128)"
s = conn()
assert ask(s, b'{"jsonrpc":"2.0","id":1,"method":"vm.info"}\n') is not None, "no answer after the flood"
s.close()
print(f"security: {len(many)} connections at once: {alive} kept (cap 128), the rest closed; answers after")
EOF
    kill -0 "$pid" 2>/dev/null || it_fail "the helper died" || return 1
    [[ $(it_rpc "$socket" vm.info | jq -r .state) == stopped ]] || it_fail "the helper stopped answering" || return 1
    local denials
    denials=$(jq -s '[.[] | select(.result == "denied" and .identity == "automated")] | length' "$bundle/logs/mcp-audit.jsonl")
    [[ $denials -ge 2 ]] || it_fail "expected the unsigned client's refusals in the audit log, found $denials" || return 1
    [[ $(it_mode "$bundle/logs/mcp-audit.jsonl") == 600 ]] || it_fail "the audit log is not 0600" || return 1
    echo "security: refusals audited (0600 log); the helper answers after all of it"

    it_rpc "$socket" helper.shutdown >/dev/null 2>&1 || true
    it_wait_for 10 bash -c "! kill -0 $pid 2>/dev/null" || it_fail "the helper did not shut down" || return 1
    pid=
}
