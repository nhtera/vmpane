# Guest agent in a macOS guest (the golden macOS bundle with a user, its agent installed from the tools share as
# a user would; build-golden-macos-user.sh): connects after boot with its user session (auto-login), exec as
# root and as the user with output and exit codes, 256 MiB push and pull with matching SHA-256, the guest clock
# within 1 s after a live-snapshot restore, a running disk snapshot refused (macOS cannot freeze), and a long line typed through
# vm.input.text arriving intact (macOS guests lost keys typed in one burst).
# Sourced by scripts/itest.sh with $APP set.

source "$VMPANE_ROOT/itest/lib/common.sh"
IT_SCENARIO=agent-macos

it_agent_exec() { /usr/bin/python3 "$VMPANE_ROOT/itest/lib/agent_exec.py" "$socket" "$@"; }

it_agent_session() { it_rpc "$socket" agent.status 2>/dev/null | jq -e '.connected and .session' >/dev/null; }

scenario_run() {
    local golden work bundle pid socket start out rc big back host_sum guest_sum seconds id drift what long
    local status=0
    golden=$(it_golden_macos_user) || status=$?
    ((status == 0)) || return "$status"
    work=$(mktemp -d /tmp/vp-am.XXXXXX)
    export VMPANE_SUPPORT_DIR="$work/s"
    mkdir -p "$VMPANE_SUPPORT_DIR/VMs"
    bundle="$VMPANE_SUPPORT_DIR/VMs/M.vmpane"
    it_clone_bundle "$golden" "$bundle"
    trap 'set +e; [[ -n ${pid:-} ]] && kill -9 "$pid" 2>/dev/null; rm -rf "$work"; true' RETURN

    # 1. Connect time: the agent (LaunchDaemon) and, after the auto-login, its session helper (LaunchAgent).
    pid=$(it_start_helper "$bundle") || return 1
    socket=$(it_socket "$bundle")
    start=$SECONDS
    it_rpc "$socket" vm.start '{"headless": true}' >/dev/null || it_fail "vm.start failed" || return 1
    it_wait_for 180 it_agent_session || it_fail "the agent and its session did not connect within 180 s" || return 1
    echo "agent-macos: agent and user session connected $((SECONDS - start)) s after vm.start"
    it_rpc "$socket" agent.status | jq -c '{version, os, osVersion, proto, caps}'

    # 2. exec: identity, output, exit codes.
    out=$(it_agent_exec 'id -u') || it_fail "exec failed" || return 1
    [[ $out == 0 ]] || it_fail "as admin, id -u printed '$out'" || return 1
    out=$(it_agent_exec --user 'id -un') || it_fail "exec as the user failed" || return 1
    [[ $out == "$IT_MACOS_USER" ]] || it_fail "as user, id -un printed '$out'" || return 1
    rc=0
    it_agent_exec 'exit 7' || rc=$?
    [[ $rc == 7 ]] || it_fail "exit 7 came back as $rc" || return 1
    out=$(it_agent_exec 'echo err >&2' 2>&1 >/dev/null)
    [[ $out == err ]] || it_fail "stderr did not come back: '$out'" || return 1
    echo "agent-macos: exec as root and as $IT_MACOS_USER, stdout/stderr and exit codes OK"

    # 3. 256 MiB both ways, checked by SHA-256 on both sides.
    big="$work/big.bin"
    back="$work/back.bin"
    dd if=/dev/urandom of="$big" bs=1m count=256 2>/dev/null
    host_sum=$(shasum -a 256 "$big" | cut -d' ' -f1)
    start=$(/usr/bin/python3 -c 'import time; print(time.time())')
    it_rpc "$socket" agent.file.push "{\"hostPath\": \"$big\", \"guestPath\": \"/private/tmp/big.bin\"}" >/dev/null \
        || it_fail "push failed" || return 1
    seconds=$(/usr/bin/python3 -c "import time; print(round(time.time() - $start, 2))")
    guest_sum=$(it_agent_exec 'shasum -a 256 /private/tmp/big.bin' | cut -d' ' -f1)
    [[ $guest_sum == "$host_sum" ]] || it_fail "pushed file differs in the guest" || return 1
    it_rpc "$socket" agent.file.pull "{\"guestPath\": \"/private/tmp/big.bin\", \"hostPath\": \"$back\"}" >/dev/null \
        || it_fail "pull failed" || return 1
    [[ $(shasum -a 256 "$back" | cut -d' ' -f1) == "$host_sum" ]] || it_fail "pulled file differs" || return 1
    echo "agent-macos: pushed 256 MiB in ${seconds} s and pulled it back, SHA-256 equal"
    rm -f "$big" "$back"
    it_agent_exec 'rm -f /private/tmp/big.bin' >/dev/null

    # 4. A long line typed in one call arrives intact: into `cat` in a Terminal window the agent opens.
    it_agent_exec --user 'rm -f /tmp/typed.txt; printf "#!/bin/sh\nexec cat > /tmp/typed.txt\n" > /tmp/catter.command; chmod +x /tmp/catter.command; open /tmp/catter.command' >/dev/null \
        || it_fail "cannot open Terminal in the guest" || return 1
    it_wait_for 30 it_agent_exec --user 'pgrep -x cat' >/dev/null || it_fail "the Terminal window did not start cat" || return 1
    sleep 2
    long=$(/usr/bin/python3 -c 'print("".join(chr(c) for c in range(0x21, 0x7F)) * 4, end="")')
    it_rpc "$socket" vm.input.text "$(jq -n --arg t "$long"$'\n' '{text: $t}')" >/dev/null || it_fail "vm.input.text failed" || return 1
    it_wait_for 20 bash -c "[[ \$(/usr/bin/python3 '$VMPANE_ROOT/itest/lib/agent_exec.py' '$socket' --user 'wc -c < /tmp/typed.txt' | tr -d ' ') == $((${#long} + 1)) ]]" \
        || it_fail "a ${#long}-character line arrived as $(it_agent_exec --user 'wc -c < /tmp/typed.txt' | tr -d ' ') bytes" || return 1
    [[ $(it_agent_exec --user 'cat /tmp/typed.txt') == "$long" ]] || it_fail "the typed line arrived changed" || return 1
    it_agent_exec --user 'pkill -x cat; osascript -e "quit app \"Terminal\""' >/dev/null || true
    echo "agent-macos: a ${#long}-character line typed in one call arrived intact"

    # 5. Clock after a live-snapshot restore (or across a pause on a locked Mac, which cannot restore).
    id=$(it_rpc "$socket" vm.snapshot.create '{"name": "clock", "kind": "live"}' | jq -r .id) || it_fail "snapshot failed" || return 1
    sleep 20
    if out=$(it_rpc "$socket" vm.snapshot.restore "{\"id\": \"$id\"}"); then
        what="a restore 20 s back"
    elif [[ $(jq -r .code <<<"$out" 2>/dev/null) == -32018 ]]; then
        echo "agent-macos: this Mac is locked, so no restore; checking the clock across a pause instead"
        it_rpc "$socket" vm.pause >/dev/null || it_fail "pause failed" || return 1
        sleep 20
        it_rpc "$socket" vm.resume >/dev/null || it_fail "resume failed" || return 1
        what="a 20 s pause"
    else
        it_fail "restore failed: $out"
        return 1
    fi
    it_wait_for 60 it_agent_session || it_fail "the agent did not reconnect after $what" || return 1
    sleep 2  # the clock sync follows the reconnect or resume
    # perl, not python3: a fresh macOS offers to install the developer tools on python3.
    out=$(it_agent_exec "perl -MTime::HiRes=time -e 'printf \"%.3f\", time'") || it_fail "cannot read the guest clock" || return 1
    drift=$(/usr/bin/python3 -c "import time; print(abs($out - time.time()))")
    /usr/bin/python3 -c "import sys; sys.exit(0 if $drift < 1 else 1)" || it_fail "guest clock off by ${drift} s after $what" || return 1
    echo "agent-macos: guest clock within $(printf '%.3f' "$drift") s of the host after $what"

    # 6. macOS cannot freeze its file systems (the agent only syncs): a disk snapshot of the running guest is
    #    refused with the way out, and the guest stays writable.
    out=$(it_rpc "$socket" vm.snapshot.create '{"name": "frozen", "kind": "disk"}') && { it_fail "a running disk snapshot was taken without a freeze"; return 1; }
    [[ $out == *"file system freeze"*"live snapshot"* ]] || it_fail "unclear refusal: $out" || return 1
    out=$(it_agent_exec 'touch /private/tmp/after-refusal && echo writable') || it_fail "exec failed after the refusal" || return 1
    [[ $out == writable ]] || it_fail "the guest file system is not writable" || return 1
    echo "agent-macos: a disk snapshot of the running guest is refused (no freeze on macOS; live snapshots instead)"

    it_rpc "$socket" vm.stop '{"mode": "force"}' >/dev/null
    it_rpc "$socket" helper.shutdown >/dev/null
    it_wait_exit "$pid" || true
    pid=
    return 0
}
