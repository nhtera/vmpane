# Guest agent in a Linux VZ guest: installed from the read-only `vmpane-tools` share as a user would, then
# over vsock: connects after boot (target < 10 s), exec round trip with identity and exit codes, 1 GiB push and
# pull with matching SHA-256 (target ≥ 100 MB/s), the guest clock within 1 s after a live-snapshot restore, and
# a disk snapshot of the running guest under the agent's file system freeze.
# Needs an app built with the Linux guest tools (guest-tools/build-linux.sh) and ~4 GiB free.
# Sourced by scripts/itest.sh with $APP set.

source "$VMPANE_ROOT/itest/lib/common.sh"
IT_SCENARIO=agent-linux

it_agent_exec() { /usr/bin/python3 "$VMPANE_ROOT/itest/lib/agent_exec.py" "$socket" "$@"; }

it_agent_connected() { [[ $(it_rpc "$socket" agent.status | jq -r .connected) == true ]]; }

scenario_run() {
    local work bundle pid socket start out id big back host_sum guest_sum seconds mbps drift rc
    [[ -f "$APP/Contents/Resources/GuestTools/linux/SHA256SUMS" ]] \
        || { echo "agent-linux: the app has no Linux guest tools (guest-tools/build-linux.sh, then rebuild)" >&2; return 77; }
    it_boot_linux_clone || return 1
    trap 'set +e; [[ -n ${pid:-} ]] && kill -9 "$pid" 2>/dev/null; rm -rf "$work"; true' RETURN

    # 1. Install from the tools share, as `sudo /mnt/vmpane-tools/install.sh`.
    it_rpc "$socket" vm.input.text '{"text": "VMPANE-INSTALL-AGENT\n"}' >/dev/null
    it_wait_for 60 grep -qa 'VMPANE-AGENT-INSTALLED' "$bundle/logs/serial.log" || it_fail "the installer did not finish" || return 1
    grep -qa 'VMPANE-AGENT-INSTALLED rc=0' "$bundle/logs/serial.log" \
        || it_fail "the installer failed: $(grep -a -B5 VMPANE-AGENT-INSTALLED "$bundle/logs/serial.log" | tr -d '\r')" || return 1
    it_wait_for 30 it_agent_connected || it_fail "the agent did not connect after the install" || return 1

    # 2. Connect time after a fresh boot.
    it_rpc "$socket" vm.stop '{"mode": "graceful"}' >/dev/null
    it_wait_for 60 bash -c "[[ \$(/usr/bin/python3 '$VMPANE_ROOT/itest/lib/rpc.py' '$socket' vm.info | jq -r .state) == stopped ]]" \
        || it_fail "the guest did not shut down" || return 1
    : >"$bundle/logs/serial.log"
    start=$SECONDS
    it_rpc "$socket" vm.start '{"headless": true}' >/dev/null || it_fail "restart failed" || return 1
    it_wait_for 60 it_agent_connected || it_fail "the agent did not connect within 60 s of the start" || return 1
    echo "agent-linux: agent connected $((SECONDS - start)) s after vm.start (target < 10 s after boot)"
    it_rpc "$socket" agent.status | jq -c '{version, os, proto, caps}'

    # 3. exec: identity, output, exit codes.
    out=$(it_agent_exec 'id -u; echo to-stderr >&2' 2>/dev/null) || it_fail "exec failed" || return 1
    [[ $out == 0 ]] || it_fail "as admin, id -u printed '$out'" || return 1
    rc=0
    it_agent_exec 'exit 7' || rc=$?
    [[ $rc == 7 ]] || it_fail "exit 7 came back as $rc" || return 1
    out=$(it_agent_exec 'echo err >&2' 2>&1 >/dev/null)
    [[ $out == err ]] || it_fail "stderr did not come back: '$out'" || return 1
    echo "agent-linux: exec as root, stdout/stderr and exit codes OK"

    # 4. 1 GiB both ways, checked by SHA-256 on both sides.
    big="$work/big.bin"
    back="$work/back.bin"
    dd if=/dev/urandom of="$big" bs=1m count=1024 2>/dev/null
    host_sum=$(shasum -a 256 "$big" | cut -d' ' -f1)
    start=$(/usr/bin/python3 -c 'import time; print(time.time())')
    it_rpc "$socket" agent.file.push "{\"hostPath\": \"$big\", \"guestPath\": \"/root/big.bin\"}" >/dev/null || it_fail "push failed" || return 1
    seconds=$(/usr/bin/python3 -c "import time; print(round(time.time() - $start, 2))")
    mbps=$(/usr/bin/python3 -c "print(int(1073741824 / $seconds / 1e6))")
    guest_sum=$(it_agent_exec 'sha256sum /root/big.bin' | cut -d' ' -f1)
    [[ $guest_sum == "$host_sum" ]] || it_fail "pushed file differs in the guest" || return 1
    echo "agent-linux: pushed 1 GiB in ${seconds} s (${mbps} MB/s, hashing included; target ≥ 100 MB/s)"
    start=$(/usr/bin/python3 -c 'import time; print(time.time())')
    it_rpc "$socket" agent.file.pull "{\"guestPath\": \"/root/big.bin\", \"hostPath\": \"$back\"}" >/dev/null || it_fail "pull failed" || return 1
    seconds=$(/usr/bin/python3 -c "import time; print(round(time.time() - $start, 2))")
    mbps=$(/usr/bin/python3 -c "print(int(1073741824 / $seconds / 1e6))")
    [[ $(shasum -a 256 "$back" | cut -d' ' -f1) == "$host_sum" ]] || it_fail "pulled file differs" || return 1
    echo "agent-linux: pulled 1 GiB in ${seconds} s (${mbps} MB/s)"
    rm -f "$big" "$back"
    it_agent_exec 'rm -f /root/big.bin' >/dev/null

    # 5. Clock after a live-snapshot restore: the guest resumes with the snapshot's time; the host resets it.
    id=$(it_rpc "$socket" vm.snapshot.create '{"name": "clock", "kind": "live"}' | jq -r .id) || it_fail "snapshot failed" || return 1
    sleep 20
    it_rpc "$socket" vm.snapshot.restore "{\"id\": \"$id\"}" >/dev/null || it_fail "restore failed" || return 1
    it_wait_for 30 it_agent_connected || it_fail "the agent did not reconnect after the restore" || return 1
    sleep 2  # the clock sync follows the reconnect
    drift=$(/usr/bin/python3 -c "import time; print(abs(float('$(it_agent_exec 'date +%s.%N')') - time.time()))")
    /usr/bin/python3 -c "import sys; sys.exit(0 if $drift < 1 else 1)" || it_fail "guest clock off by ${drift} s after the restore" || return 1
    echo "agent-linux: guest clock within $(printf '%.3f' "$drift") s of the host after a restore 20 s back"

    # 6. Disk snapshot of the running guest: frozen by the agent while the disks are cloned, then thawed.
    it_rpc "$socket" vm.snapshot.create '{"name": "frozen", "kind": "disk"}' >/dev/null || it_fail "running disk snapshot failed" || return 1
    out=$(it_agent_exec 'touch /root/after-thaw && echo writable') || it_fail "the guest stayed frozen" || return 1
    [[ $out == writable ]] || it_fail "the guest file system is not writable after the snapshot" || return 1
    echo "agent-linux: disk snapshot of the running guest (frozen, cloned, thawed)"

    it_rpc "$socket" vm.stop '{"mode": "force"}' >/dev/null
    it_rpc "$socket" helper.shutdown >/dev/null
    it_wait_exit "$pid" || true
    pid=
    return 0
}
