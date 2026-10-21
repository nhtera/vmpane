# Guest agent in a Windows 11 ARM guest on QEMU, over virtio-serial: the golden install put the agent MSI in
# (guest-tools/fetch-agent-msi.sh before building the golden). Checks: the service connects after boot, exec as
# LocalSystem with exit codes, the NAT's DNS proxy answering, 256 MiB push and pull with matching SHA-256 (target ≥ 30 MB/s on virtio-serial),
# the guest clock within 1 s after a 20 s pause, and the agent back after a suspend and a live restore.
# Sourced by scripts/itest.sh with $APP set. Exit 77 without a Windows ISO, the MSI, or 15 GiB free.

source "$VMPANE_ROOT/itest/lib/common.sh"
IT_SCENARIO=agent-windows

it_agent_exec() { /usr/bin/python3 "$VMPANE_ROOT/itest/lib/agent_exec.py" "$socket" "$@"; }
it_agent_connected() { [[ $(it_rpc "$socket" agent.status | jq -r .connected) == true ]]; }
it_now() { /usr/bin/python3 -c 'import time; print(time.time())'; }

scenario_run() {
    local golden work bundle pid socket start out rc big back host_sum guest_sum seconds drift status id
    compgen -G "$IT_WINDOWS_EXTRA/*.msi" >/dev/null || { echo "agent-windows: no agent MSI (guest-tools/fetch-agent-msi.sh)" >&2; return 77; }
    (($(df -g "$HOME" | awk 'NR == 2 {print $4}') >= 15)) || { echo "agent-windows: needs 15 GiB free" >&2; return 77; }
    golden=$(it_golden_windows) || { status=$?; return "$status"; }
    [[ -f $golden/.agent ]] || it_fail "the golden Windows VM has no agent" || return 1
    work=$(mktemp -d /tmp/vp-aw.XXXXXX)
    export VMPANE_SUPPORT_DIR="$work/s"
    mkdir -p "$VMPANE_SUPPORT_DIR/VMs"
    bundle="$VMPANE_SUPPORT_DIR/VMs/W.vmpane"
    it_clone_bundle "$golden" "$bundle"
    rm -f "$bundle/.agent"
    trap 'set +e; [[ -n ${pid:-} ]] && kill -TERM "$pid" 2>/dev/null && it_wait_exit "$pid" 150; rm -rf "$work"; true' RETURN

    # 1. Boot; the service connects over the virtio-serial port.
    pid=$(it_start_helper "$bundle") || return 1
    socket=$(it_socket "$bundle")
    start=$SECONDS
    out=$(it_rpc "$socket" vm.start '{"headless": true}') || it_fail "vm.start failed: $out" || return 1
    it_wait_for 180 it_agent_connected || it_fail "the agent did not connect within 180 s of the start" || return 1
    echo "agent-windows: agent connected $((SECONDS - start)) s after vm.start"
    it_rpc "$socket" agent.status | jq -c '{version, os, osVersion, proto, caps}'

    # 2. exec as LocalSystem, exit codes, stderr.
    out=$(it_agent_exec 'whoami' | tr -d '\r') || it_fail "exec failed" || return 1
    [[ $out == "nt authority\\system" ]] || it_fail "as admin, whoami printed '$out'" || return 1
    rc=0
    it_agent_exec 'exit /b 7' || rc=$?
    [[ $rc == 7 ]] || it_fail "exit 7 came back as $rc" || return 1
    echo "agent-windows: exec as LocalSystem and exit codes OK"

    # The NAT's DNS proxy (10.0.2.3) answers: sandboxed QEMU reads the Mac's name servers (needs a Mac online).
    if host -W 3 github.com >/dev/null 2>&1; then
        out=$(it_agent_exec 'nslookup github.com 10.0.2.3' 2>&1 | tr -d '\r') || true
        [[ $out == *"Name:"*"github.com"* && $out != *"timed out"* ]] ||
            { echo "$out"; it_fail "the NAT's DNS (10.0.2.3) did not answer"; return 1; }
        echo "agent-windows: the NAT's DNS (10.0.2.3) answers"
    else
        echo "agent-windows: the Mac resolves no names; the NAT's DNS is not checked"
    fi

    # 3. 256 MiB both ways over virtio-serial.
    big="$work/big.bin"
    back="$work/back.bin"
    dd if=/dev/urandom of="$big" bs=1m count=256 2>/dev/null
    host_sum=$(shasum -a 256 "$big" | cut -d' ' -f1)
    start=$(it_now)
    out=$(it_rpc "$socket" agent.file.push "{\"hostPath\": \"$big\", \"guestPath\": \"C:\\\\Windows\\\\Temp\\\\big.bin\"}") \
        || it_fail "push failed: $out" || return 1
    seconds=$(/usr/bin/python3 -c "import time; print(round(time.time() - $start, 2))")
    echo "agent-windows: pushed 256 MiB in ${seconds} s ($(/usr/bin/python3 -c "print(int(268435456 / $seconds / 1e6))") MB/s; target ≥ 30 MB/s)"
    guest_sum=$(it_agent_exec 'certutil -hashfile C:\Windows\Temp\big.bin SHA256' | tr -d '\r' | sed -n 2p | tr -d ' ' | tr '[:upper:]' '[:lower:]')
    [[ $guest_sum == "$host_sum" ]] || it_fail "pushed file differs in the guest ($guest_sum)" || return 1
    start=$(it_now)
    out=$(it_rpc "$socket" agent.file.pull "{\"guestPath\": \"C:\\\\Windows\\\\Temp\\\\big.bin\", \"hostPath\": \"$back\"}") \
        || it_fail "pull failed: $out" || return 1
    seconds=$(/usr/bin/python3 -c "import time; print(round(time.time() - $start, 2))")
    [[ $(shasum -a 256 "$back" | cut -d' ' -f1) == "$host_sum" ]] || it_fail "pulled file differs" || return 1
    echo "agent-windows: pulled 256 MiB in ${seconds} s ($(/usr/bin/python3 -c "print(int(268435456 / $seconds / 1e6))") MB/s)"
    rm -f "$big" "$back"
    it_agent_exec 'del C:\Windows\Temp\big.bin' >/dev/null || it_fail "deleting the pushed file failed" || return 1

    # 4. Clock after a 20 s pause (the host sets it on resume).
    it_rpc "$socket" vm.pause >/dev/null || it_fail "pause failed" || return 1
    sleep 20
    it_rpc "$socket" vm.resume >/dev/null || it_fail "resume failed" || return 1
    sleep 3
    out=$(it_agent_exec 'powershell -NoProfile -Command "[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()"' | tr -d '\r') \
        || it_fail "no agent after the 20 s pause" || return 1
    drift=$(/usr/bin/python3 -c "import time; print(abs($out / 1000 - time.time()))")
    /usr/bin/python3 -c "import sys; sys.exit(0 if $drift < 1 else 1)" || it_fail "guest clock off by ${drift} s after a pause" || return 1
    echo "agent-windows: guest clock within $(printf '%.3f' "$drift") s of the host after a 20 s pause"

    # 5. Suspend and start again, then restore a live snapshot: each time QEMU is a new process while the guest
    # (and its agent) carries on from its saved memory; the agent must come back without a Windows restart.
    it_rpc "$socket" vm.suspend >/dev/null || it_fail "suspend failed" || return 1
    it_rpc "$socket" vm.start '{"headless": true}' >/dev/null || it_fail "start after suspend failed" || return 1
    start=$SECONDS
    it_wait_for 30 it_agent_connected || it_fail "the agent did not reconnect within 30 s of resuming a suspended VM" || return 1
    out=$(it_agent_exec 'echo back' | tr -d '\r') || it_fail "no exec after resuming a suspended VM" || return 1
    [[ $out == back ]] || it_fail "after resuming, echo printed '$out'" || return 1
    echo "agent-windows: agent back $((SECONDS - start)) s after resuming a suspended VM"
    id=$(it_rpc "$socket" vm.snapshot.create '{"name": "live", "kind": "live"}' | jq -r '.id // empty')
    [[ -n $id ]] || it_fail "live snapshot failed" || return 1
    out=$(it_rpc "$socket" vm.snapshot.restore "{\"id\": \"$id\"}") || it_fail "restore failed: $out" || return 1
    start=$SECONDS
    it_wait_for 30 it_agent_connected || it_fail "the agent did not reconnect within 30 s of a live restore" || return 1
    out=$(it_agent_exec 'echo back' | tr -d '\r') || it_fail "no exec after a live restore" || return 1
    [[ $out == back ]] || it_fail "after the restore, echo printed '$out'" || return 1
    echo "agent-windows: agent back $((SECONDS - start)) s after restoring a live snapshot"

    it_rpc "$socket" vm.stop '{"mode": "graceful"}' >/dev/null
    it_wait_for 150 bash -c "[[ \$(/usr/bin/python3 '$VMPANE_ROOT/itest/lib/rpc.py' '$socket' vm.info | jq -r .state) == stopped ]]" \
        || it_fail "Windows did not shut down within 150 s" || return 1
    it_rpc "$socket" helper.shutdown >/dev/null
    it_wait_exit "$pid" 30 || true
    pid=
    return 0
}
