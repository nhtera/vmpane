# Guest agent in a Linux VZ guest: installed from the read-only `vmpane-tools` share as a user would, then
# over vsock: connects after boot (target < 10 s), exec round trip with identity and exit codes, 1 GiB push and
# pull with matching SHA-256 (target ≥ 100 MB/s), the guest clock within 1 s after a live-snapshot restore, and
# a disk snapshot of the running guest under the agent's file system freeze, the session helper of a
# logged-in user running `as: "user"` commands, and an older agent updating itself from the app's tools.
# Needs an app built with the Linux guest tools (guest-tools/build-linux.sh) and ~4 GiB free.
# Sourced by scripts/itest.sh with $APP set.

source "$VMPANE_ROOT/itest/lib/common.sh"
IT_SCENARIO=agent-linux

it_agent_exec() { /usr/bin/python3 "$VMPANE_ROOT/itest/lib/agent_exec.py" "$socket" "$@"; }

it_agent_connected() { [[ $(it_rpc "$socket" agent.status | jq -r .connected) == true ]]; }

scenario_run() {
    local work bundle pid socket start out id big back host_sum guest_sum seconds mbps drift rc what
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
    #    A locked Mac cannot restore saved memory (macLocked): then the same check across a 20 s pause.
    id=$(it_rpc "$socket" vm.snapshot.create '{"name": "clock", "kind": "live"}' | jq -r .id) || it_fail "snapshot failed" || return 1
    sleep 20
    if out=$(it_rpc "$socket" vm.snapshot.restore "{\"id\": \"$id\"}"); then
        what="a restore 20 s back"
    elif [[ $(jq -r .code <<<"$out" 2>/dev/null) == -32018 ]]; then
        echo "agent-linux: this Mac is locked, so no restore; checking the clock across a pause instead"
        it_rpc "$socket" vm.pause >/dev/null || it_fail "pause failed" || return 1
        sleep 20
        it_rpc "$socket" vm.resume >/dev/null || it_fail "resume failed" || return 1
        what="a 20 s pause"
    else
        it_fail "restore failed: $out"
        return 1
    fi
    it_wait_for 30 it_agent_connected || it_fail "the agent did not reconnect after $what" || return 1
    sleep 2  # the clock sync follows the reconnect or resume
    drift=$(/usr/bin/python3 -c "import time; print(abs(float('$(it_agent_exec 'date +%s.%N')') - time.time()))")
    /usr/bin/python3 -c "import sys; sys.exit(0 if $drift < 1 else 1)" || it_fail "guest clock off by ${drift} s after $what" || return 1
    echo "agent-linux: guest clock within $(printf '%.3f' "$drift") s of the host after $what"

    # 6. Disk snapshot of the running guest: frozen by the agent while the disks are cloned, then thawed.
    it_rpc "$socket" vm.snapshot.create '{"name": "frozen", "kind": "disk"}' >/dev/null || it_fail "running disk snapshot failed" || return 1
    out=$(it_agent_exec 'touch /root/after-thaw && echo writable') || it_fail "the guest stayed frozen" || return 1
    [[ $out == writable ]] || it_fail "the guest file system is not writable after the snapshot" || return 1
    echo "agent-linux: disk snapshot of the running guest (frozen, cloned, thawed)"

    # 7. A user session: auto-login `ubuntu` on tty2 and switch to it (logind's foreground seat session); its
    #    systemd user instance starts the session helper, and `as: "user"` runs as ubuntu.
    it_agent_exec 'mkdir -p /etc/systemd/system/getty@tty2.service.d && printf "[Service]\nExecStart=\nExecStart=-/sbin/agetty --autologin ubuntu --noclear %%I \$TERM\n" >/etc/systemd/system/getty@tty2.service.d/autologin.conf && systemctl daemon-reload && systemctl restart getty@tty2 && chvt 2' >/dev/null \
        || it_fail "cannot log a user in" || return 1
    it_wait_for 60 bash -c "[[ \$(/usr/bin/python3 '$VMPANE_ROOT/itest/lib/rpc.py' '$socket' agent.status | jq -r .session) == true ]]" \
        || { it_agent_exec 'loginctl list-sessions --no-legend; for f in /run/systemd/sessions/[0-9]*; do case $f in *.ref) ;; *) grep -HE "^(UID|ACTIVE|STATE|TYPE)=" "$f";; esac; done; ls -l /run/vmpane-agent.sock; systemctl --global is-enabled vmpane-session.service; journalctl -u vmpane-agent -n 15 --no-pager; journalctl _UID=1000 -n 15 --no-pager' >&2
             it_fail "the session helper did not connect after the login"; return 1; }
    out=$(it_agent_exec --user 'id -un') || it_fail "exec as the user failed" || return 1
    [[ $out == ubuntu ]] || it_fail "as user, id -un printed '$out'" || return 1
    echo "agent-linux: session helper connected for the logged-in user; as:user runs as $out"

    # 8. An older agent updates by itself: a debug agent pretending 0.9.0 (VMPANE_TEST_AGENT_VERSION, which a
    #    release agent ignores) replaces the installed one; the helper sends the runtime's tools and runs
    #    install.sh, and the agent comes back as this VMPane's version.
    (cd "$VMPANE_ROOT/agent" && cargo build --locked --quiet --target aarch64-unknown-linux-musl -p vmpane-agent) \
        || it_fail "cannot build a debug agent" || return 1
    it_rpc "$socket" agent.file.push "{\"hostPath\": \"$VMPANE_ROOT/agent/target/aarch64-unknown-linux-musl/debug/vmpane-agent\", \"guestPath\": \"/root/old-agent\", \"overwrite\": true}" >/dev/null \
        || it_fail "cannot push the debug agent" || return 1
    it_agent_exec 'install -m 0755 /root/old-agent /usr/local/bin/vmpane-agent && rm /root/old-agent && mkdir -p /etc/systemd/system/vmpane-agent.service.d && printf "[Service]\nEnvironment=VMPANE_TEST_AGENT_VERSION=0.9.0\n" >/etc/systemd/system/vmpane-agent.service.d/old.conf && systemctl daemon-reload && systemd-run --quiet --collect --on-active=1 systemctl restart vmpane-agent' >/dev/null \
        || it_fail "cannot install the older agent" || return 1
    it_wait_for 60 bash -c "[[ \$(/usr/bin/python3 '$VMPANE_ROOT/itest/lib/rpc.py' '$socket' agent.status | jq -r .version) == 0.9.0 ]]" \
        || it_fail "the older agent did not connect" || return 1
    local version
    version=$("$APP/Contents/Helpers/vmpane" --version 2>/dev/null | awk '{print $NF}')
    it_wait_for 180 bash -c "[[ \$(/usr/bin/python3 '$VMPANE_ROOT/itest/lib/rpc.py' '$socket' agent.status | jq -r '.version + \" \" + (.outdated | tostring)') == '$version false' ]]" \
        || { it_rpc "$socket" agent.status >&2; it_agent_exec 'cat /var/log/vmpane-tools-update.log; journalctl -u vmpane-agent -n 20 --no-pager' >&2 || true
             it_fail "the older agent was not updated to $version"; return 1; }
    # The helper sees the new agent within a second, then records the update.
    it_wait_for 15 grep -q '"method":"agent.toolsUpdate".*"result":"ok"' "$bundle/logs/mcp-audit.jsonl" \
        || it_fail "the update is not in the audit log" || return 1
    it_agent_exec 'rm -rf /etc/systemd/system/vmpane-agent.service.d && systemctl daemon-reload' >/dev/null || true
    echo "agent-linux: an agent claiming 0.9.0 updated itself to $version"

    it_rpc "$socket" vm.stop '{"mode": "force"}' >/dev/null
    it_rpc "$socket" helper.shutdown >/dev/null
    it_wait_exit "$pid" || true
    pid=
    return 0
}
