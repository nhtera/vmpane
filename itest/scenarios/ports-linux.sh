# Port forwarding into a Linux VZ guest (Phase 09): rules added live through vm.settings.apply reach services in
# the guest (TCP: a 64 MiB download checked by SHA-256, with its speed; UDP: an echo), the guest's address is
# found and checked by the helper (DHCP lease / ARP), a removed rule stops at once, and rules come back after a
# restart. Needs an app built with the Linux guest tools (the agent starts the guest's services).
# Sourced by scripts/itest.sh with $APP set.

source "$VMPANE_ROOT/itest/lib/common.sh"
IT_SCENARIO=ports-linux

it_agent_exec() { /usr/bin/python3 "$VMPANE_ROOT/itest/lib/agent_exec.py" "$socket" "$@"; }
it_agent_connected() { [[ $(it_rpc "$socket" agent.status | jq -r .connected) == true ]]; }
it_status_of() { it_rpc "$socket" vm.ports.list | jq -r --arg id "$1" '.rules[] | select(.id == $id) | .status'; }

# Starts the guest's services, detached from the agent's exec: a web server over /root/www and a UDP echo.
it_guest_services() {
    it_agent_exec 'mkdir -p /root/www && [ -f /root/www/big.bin ] || head -c 67108864 /dev/urandom >/root/www/big.bin
        setsid -f python3 -m http.server 8000 --directory /root/www >/dev/null 2>&1 </dev/null
        setsid -f python3 -c "
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.bind((\"0.0.0.0\", 5353))
while True:
    data, peer = s.recvfrom(65536)
    s.sendto(b\"echo:\" + data, peer)
" >/dev/null 2>&1 </dev/null
        sleep 1; ss -ltnu | grep -E ":(8000|5353) "' >/dev/null
}

it_udp_echo() {
    /usr/bin/python3 - "$1" <<'PY'
import socket, sys
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.settimeout(3)
s.sendto(b"ping", ("127.0.0.1", int(sys.argv[1])))
print(s.recvfrom(100)[0].decode())
PY
}

scenario_run() {
    local work bundle pid socket http udp rules guest_sum host_sum start seconds mbps out
    [[ -f "$APP/Contents/Resources/GuestTools/linux/SHA256SUMS" ]] \
        || { echo "ports-linux: the app has no Linux guest tools (guest-tools/build-linux.sh, then rebuild)" >&2; return 77; }
    it_boot_linux_clone || return 1
    trap 'set +e; [[ -n ${pid:-} ]] && kill -9 "$pid" 2>/dev/null; rm -rf "$work"; true' RETURN
    it_rpc "$socket" vm.input.text '{"text": "VMPANE-INSTALL-AGENT\n"}' >/dev/null
    it_wait_for 60 grep -qa 'VMPANE-AGENT-INSTALLED rc=0' "$bundle/logs/serial.log" || it_fail "the agent did not install" || return 1
    it_wait_for 30 it_agent_connected || it_fail "the agent did not connect" || return 1
    it_guest_services || it_fail "the guest's services did not start" || return 1

    # 1. Rules added live.
    http=$((20000 + RANDOM % 20000))
    udp=$((http + 1))
    rules=$(jq -nc --argjson h "$http" --argjson u "$udp" '{patch: {portForwards: [
        {id: "web", proto: "tcp", hostAddress: "127.0.0.1", hostPort: $h, guestPort: 8000, origin: "user"},
        {id: "echo", proto: "udp", hostAddress: "127.0.0.1", hostPort: $u, guestPort: 5353, origin: "user"}]}}')
    out=$(it_rpc "$socket" vm.settings.apply "$rules") || it_fail "vm.settings.apply failed" || return 1
    [[ $(jq -r '.fields.portForwards' <<<"$out") == applied ]] || it_fail "the rules did not apply live: $out" || return 1
    [[ $(it_status_of web) == listening && $(it_status_of echo) == listening ]] \
        || it_fail "not listening: $(it_rpc "$socket" vm.ports.list | jq -c .)" || return 1

    # 2. TCP: a 64 MiB download, byte-identical.
    guest_sum=$(it_agent_exec 'sha256sum /root/www/big.bin' | cut -d' ' -f1)
    start=$(/usr/bin/python3 -c 'import time; print(time.time())')
    curl -sf --max-time 60 "http://127.0.0.1:$http/big.bin" -o "$work/big.bin" || it_fail "the download through the forward failed" || return 1
    seconds=$(/usr/bin/python3 -c "import time; print(round(time.time() - $start, 3))")
    host_sum=$(shasum -a 256 "$work/big.bin" | cut -d' ' -f1)
    [[ $host_sum == "$guest_sum" ]] || it_fail "the download differs from the guest's file" || return 1
    mbps=$(/usr/bin/python3 -c "print(int(67108864 * 8 / $seconds / 1e6))")
    echo "ports-linux: 64 MiB through 127.0.0.1:$http → guest:8000 in ${seconds} s ($mbps Mbit/s, target ≥ 1000), SHA-256 matches"

    # 3. UDP echo.
    out=$(it_udp_echo "$udp") || it_fail "no UDP reply through the forward" || return 1
    [[ $out == echo:ping ]] || it_fail "UDP reply was '$out'" || return 1
    echo "ports-linux: UDP 127.0.0.1:$udp → guest:5353 answers"

    # 4. Removed live: the port closes at once.
    it_rpc "$socket" vm.settings.apply '{"patch": {"portForwards": []}}' >/dev/null
    if curl -sf --max-time 3 "http://127.0.0.1:$http/" >/dev/null; then it_fail "the removed rule still forwards"; return 1; fi
    echo "ports-linux: a removed rule stops forwarding"

    # 5. Rules survive a restart.
    it_rpc "$socket" vm.settings.apply "$rules" >/dev/null
    it_rpc "$socket" vm.stop '{"mode": "graceful"}' >/dev/null
    it_wait_for 60 bash -c "[[ \$(/usr/bin/python3 '$VMPANE_ROOT/itest/lib/rpc.py' '$socket' vm.info | jq -r .state) == stopped ]]" \
        || it_fail "the guest did not shut down" || return 1
    [[ $(it_status_of web) == inactive ]] || it_fail "a stopped VM's rule is $(it_status_of web)" || return 1
    it_rpc "$socket" vm.start '{"headless": true}' >/dev/null || it_fail "restart failed" || return 1
    it_wait_for 60 it_agent_connected || it_fail "the agent did not reconnect" || return 1
    it_guest_services || it_fail "the guest's services did not restart" || return 1
    curl -sf --max-time 30 "http://127.0.0.1:$http/" >/dev/null || it_fail "after a restart the forward does not answer" || return 1
    echo "ports-linux: rules are back after a restart"
}
