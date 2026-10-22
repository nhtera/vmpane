# Desktop apps and agent sign-in through `vmpane mcp` (agent edge, Phase 03), in real guests:
# - vm_exec desktop opens a GUI app on the signed-in user's screen (Windows: Character Map; macOS: TextEdit by its
#   path), it shows on the screen, and the kill switch closes it;
# - vm_sign_in: signed in already → nothing typed (also with the session helper killed: a helper going away is
#   no lock); locked (Windows: LockWorkStation; macOS: ctrl+cmd+q)
#   → signed in with the password kept for the VM (VMPane's dev store), as its root service reports;
# - the password and its SHA-256 are in none of the MCP replies, the VM's audit log (typed text recorded) or the
#   helper's logs. (The question asked at Run commands is a unit test: here it would be a dialog on the Mac's screen.)
# Windows: QEMU, after automatic sign-in, with the agent under test (VMPANE_ITEST_WINDOWS_AGENT, else
# agent/target/aarch64-pc-windows-msvc/release/vmpane-agent.exe); skipped without the golden or 15 GiB free.
# macOS: the golden with a user and the app's guest tools. Linux waits for a desktop image (Phase 04).
# Unsigned apps only: a Developer ID app keeps the password in the Keychain, which only the app writes.
# Sourced by scripts/itest.sh with $APP set.

source "$VMPANE_ROOT/itest/lib/common.sh"
IT_SCENARIO=desktop-sign-in

# MCP replies of this run (checked for the password at the end).
DSI_TRANSCRIPT=""

it_dsi() { DSI_TRANSCRIPT=$DSI_TRANSCRIPT /usr/bin/python3 "$VMPANE_ROOT/itest/lib/desktop_sign_in.py" "$@"; }

# Lets agents sign the VM behind $socket in, at level $1, typed text recorded; keeps password $2 in the dev store.
it_dsi_allow() {
    local level=$1 password=$2 id
    it_rpc "$socket" vm.settings.apply "$(jq -n --arg level "$level" \
        '{patch: {mcp: {policy: $level, confirmExec: false, autoSnapshot: false, auditTypedText: true, signIn: true}}}')" >/dev/null \
        || return 1
    id=$(it_rpc "$socket" vm.info | jq -r .id | tr '[:upper:]' '[:lower:]')
    install -d -m 0700 "$VMPANE_SUPPORT_DIR/sign-in"
    (umask 077 && printf '%s' "$password" >"$VMPANE_SUPPORT_DIR/sign-in/$id")
}

# Whether the desktop app runs: $1, a command that exits 0 while it does and 1 once it is gone (pgrep, findstr);
# any other exit (the check itself failed) is an error, never "gone".
it_dsi_app() {
    local status=0
    /usr/bin/python3 "$VMPANE_ROOT/itest/lib/agent_exec.py" "$socket" --user "$1" >/dev/null || status=$?
    case $status in
        0) echo running ;; 1) echo gone ;; *) echo "error $status" ;;
    esac
}

# The kill switch closes the desktop app ($1: the check for it_dsi_app).
it_dsi_kill_closes() {
    local check=$1 cli="$APP/Contents/Helpers/vmpane" state deadline
    state=$(it_dsi_app "$check")
    if [[ $state != running ]]; then
        /usr/bin/python3 "$VMPANE_ROOT/itest/lib/agent_exec.py" "$socket" 'ps -axo pid,ppid,user,comm' | grep -iE 'textedit|charmap|vmpane' >&2
        it_fail "the desktop app is not running ($state)"
        return 1
    fi
    "$cli" mcp kill >/dev/null || it_fail "vmpane mcp kill failed" || return 1
    sleep 2
    it_rpc "$socket" mcp.enableAll >/dev/null || it_fail "the app could not release the kill switch" || return 1
    deadline=$((SECONDS + 15))
    while state=$(it_dsi_app "$check") && [[ $state == running ]] && ((SECONDS < deadline)); do sleep 1; done
    [[ $state == gone ]] || { it_fail "the kill switch did not close the desktop app ($state)"; return 1; }
    echo "desktop-sign-in: the kill switch closed the desktop app"
}

# The password and its SHA-256 appear nowhere VMPane writes ($1: the password).
it_dsi_no_leak() {
    local password=$1 digest audit
    digest=$(printf '%s' "$password" | shasum -a 256 | cut -c1-64)
    audit="$bundle/logs/mcp-audit.jsonl"
    grep -q '"vm.signIn"' "$audit" || it_fail "vm.signIn is not in the audit log" || return 1
    for file in "$DSI_TRANSCRIPT" "$audit" "$VMPANE_SUPPORT_DIR"/helper-*.log; do
        if grep -qF -e "$password" -e "$digest" "$file"; then it_fail "the password is in $(basename "$file")"; return 1; fi
    done
    if /usr/bin/log show --info --debug --last 20m --predicate 'subsystem BEGINSWITH "app.vmpane"' 2>/dev/null \
        | grep -qF -e "$password" -e "$digest"; then
        it_fail "the password is in the unified log"
        return 1
    fi
    echo "desktop-sign-in: the password is in no reply, audit line or log"
}

scenario_windows() {
    local golden work bundle pid socket status agent cli="$APP/Contents/Helpers/vmpane"
    (($(df -g "$HOME" | awk 'NR == 2 {print $4}') >= 15)) || { echo "desktop-sign-in: Windows needs 15 GiB free" >&2; return 77; }
    agent=${VMPANE_ITEST_WINDOWS_AGENT:-$VMPANE_ROOT/agent/target/aarch64-pc-windows-msvc/release/vmpane-agent.exe}
    [[ -f $agent ]] || { echo "desktop-sign-in: no Windows agent under test (cargo xwin build)" >&2; return 77; }
    golden=$(it_golden_windows) || { status=$?; return "$status"; }
    work=$(mktemp -d /tmp/vp-dsi.XXXXXX)
    export VMPANE_SUPPORT_DIR="$work/s"
    DSI_TRANSCRIPT="$work/transcript.jsonl"
    mkdir -p "$VMPANE_SUPPORT_DIR/VMs"
    bundle="$VMPANE_SUPPORT_DIR/VMs/W.vmpane"
    it_clone_bundle "$golden" "$bundle"
    trap 'set +e; [[ -n ${pid:-} ]] && kill -TERM "$pid" 2>/dev/null && it_wait_exit "$pid" 150; rm -rf "$work"; trap - RETURN; true' RETURN
    pid=$(it_start_helper "$bundle") || return 1
    socket=$(it_socket "$bundle")
    it_rpc "$socket" vm.start '{"headless": true}' >/dev/null || it_fail "vm.start failed" || return 1
    it_wait_for 180 bash -c "/usr/bin/python3 '$VMPANE_ROOT/itest/lib/rpc.py' '$socket' agent.status | jq -e .connected >/dev/null" \
        || it_fail "the agent did not connect" || return 1
    it_windows_autologon "$socket" "$work" "$agent" || it_fail "no signed-in desktop after turning on automatic sign-in" || return 1
    it_rpc "$socket" agent.status | jq -e '.caps | index("desktop") and index("session.state")' >/dev/null \
        || it_fail "the agent under test has no desktop or session.state cap" || return 1
    it_wait_windows_desktop "$socket" 120 || it_fail "no Windows desktop" || return 1
    sleep 20  # first-logon animations and startup apps settle
    # Desktop apps are commands: Run commands.
    it_dsi_allow exec "$IT_WINDOWS_PASSWORD" || it_fail "cannot let agents sign in" || return 1
    it_dsi launch "$cli" windows || { it_fail "the desktop launch failed"; return 1; }
    it_dsi_kill_closes 'tasklist /NH /FI "IMAGENAME eq charmap.exe" | findstr /I charmap' || return 1
    it_dsi_allow control "$IT_WINDOWS_PASSWORD" || return 1

    it_dsi sign-in "$cli" already_signed_in || { it_fail "sign-in while signed in"; return 1; }
    # A session helper going away is no lock: still signed in, nothing typed.
    /usr/bin/python3 "$VMPANE_ROOT/itest/lib/agent_exec.py" "$socket" --user 'taskkill /F /IM vmpane-agent.exe /FI "SESSION ne 0"' >/dev/null
    it_dsi sign-in "$cli" already_signed_in || { it_fail "sign-in after the session helper was killed"; return 1; }
    it_wait_for 60 bash -c "/usr/bin/python3 '$VMPANE_ROOT/itest/lib/rpc.py' '$socket' agent.status | jq -e .session >/dev/null" \
        || it_fail "the session helper did not come back" || return 1
    /usr/bin/python3 "$VMPANE_ROOT/itest/lib/agent_exec.py" "$socket" --user 'rundll32.exe user32.dll,LockWorkStation' >/dev/null
    sleep 5
    it_dsi sign-in "$cli" signed_in || { it_screenshot "$socket" "$VMPANE_ROOT/itest/results/desktop-sign-in-windows-failure.png" 1600; it_fail "the locked session was not signed in"; return 1; }
    it_dsi_no_leak "$IT_WINDOWS_PASSWORD"
}

scenario_macos() {
    local golden work bundle pid socket status cli="$APP/Contents/Helpers/vmpane"
    it_require_unlocked || return 77
    golden=$(it_golden_macos_user) || { status=$?; return "$status"; }
    work=$(mktemp -d /tmp/vp-dsm.XXXXXX)
    export VMPANE_SUPPORT_DIR="$work/s"
    DSI_TRANSCRIPT="$work/transcript.jsonl"
    mkdir -p "$VMPANE_SUPPORT_DIR/VMs"
    bundle="$VMPANE_SUPPORT_DIR/VMs/M.vmpane"
    it_clone_bundle "$golden" "$bundle"
    trap 'set +e; [[ -n ${pid:-} ]] && kill -9 "$pid" 2>/dev/null && it_wait_exit "$pid" 10; rm -rf "$work"; trap - RETURN; true' RETURN
    pid=$(it_start_helper "$bundle") || return 1
    socket=$(it_socket "$bundle")
    it_rpc "$socket" vm.start '{"headless": true}' >/dev/null || it_fail "vm.start failed" || return 1
    it_wait_for 240 bash -c "/usr/bin/python3 '$VMPANE_ROOT/itest/lib/rpc.py' '$socket' agent.status 2>/dev/null \
        | jq -e '.connected and .session' >/dev/null" || it_fail "the agent's user session did not connect" || return 1
    it_rpc "$socket" agent.status | jq -e '.caps | index("desktop") and index("session.state")' >/dev/null \
        || it_fail "the golden's guest tools have no desktop or session.state cap" || return 1
    sleep 15  # the desktop and its first-login extras settle
    it_dsi_allow exec "$IT_MACOS_PASSWORD" || it_fail "cannot let agents sign in" || return 1
    it_dsi launch "$cli" macos || { it_fail "the desktop launch failed"; return 1; }
    it_dsi_kill_closes 'pgrep -x TextEdit' || return 1
    it_dsi_allow control "$IT_MACOS_PASSWORD" || return 1

    it_dsi sign-in "$cli" already_signed_in || { it_fail "sign-in while signed in"; return 1; }
    it_dsi lock "$cli" || { it_fail "the lock shortcut failed"; return 1; }
    sleep 5
    it_dsi sign-in "$cli" signed_in || { it_screenshot "$socket" "$VMPANE_ROOT/itest/results/desktop-sign-in-macos-failure.png" 1600; it_fail "the locked session was not signed in"; return 1; }
    it_dsi_no_leak "$IT_MACOS_PASSWORD"
}

scenario_run() {
    local status=0
    it_signed && { echo "desktop-sign-in: skipped on a signed app (the Keychain store is the app's)"; return 77; }
    scenario_macos || return 1
    scenario_windows || status=$?
    [[ $status == 77 ]] && { echo "desktop-sign-in: Windows part skipped"; return 0; }
    return "$status"
}
