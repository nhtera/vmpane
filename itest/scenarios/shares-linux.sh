# Shared folders in a Linux VZ guest (Phase 09): the agent mounts the virtiofs shares at /mnt/vmpane when it
# connects; folders shared while the VM runs appear there; a 100 MB file round-trips byte-identical both ways;
# a read-only share refuses writes. Needs an app built with the Linux guest tools.
# Sourced by scripts/itest.sh with $APP set.

source "$VMPANE_ROOT/itest/lib/common.sh"
IT_SCENARIO=shares-linux

it_agent_exec() { /usr/bin/python3 "$VMPANE_ROOT/itest/lib/agent_exec.py" "$socket" "$@"; }
it_agent_connected() { [[ $(it_rpc "$socket" agent.status | jq -r .connected) == true ]]; }

scenario_run() {
    local work bundle pid socket rw ro patch out host_sum guest_sum start seconds
    [[ -f "$APP/Contents/Resources/GuestTools/linux/SHA256SUMS" ]] \
        || { echo "shares-linux: the app has no Linux guest tools (guest-tools/build-linux.sh, then rebuild)" >&2; return 77; }
    it_boot_linux_clone || return 1
    trap 'set +e; [[ -n ${pid:-} ]] && kill -9 "$pid" 2>/dev/null; rm -rf "$work"; true' RETURN
    it_rpc "$socket" vm.input.text '{"text": "VMPANE-INSTALL-AGENT\n"}' >/dev/null
    it_wait_for 60 grep -qa 'VMPANE-AGENT-INSTALLED rc=0' "$bundle/logs/serial.log" || it_fail "the agent did not install" || return 1
    it_wait_for 30 it_agent_connected || it_fail "the agent did not connect" || return 1

    # 1. The share root is mounted once the agent is there (with nothing shared yet).
    it_wait_for 20 it_agent_exec 'mountpoint -q /mnt/vmpane' || it_fail "/mnt/vmpane is not mounted" || return 1

    # 2. Folders shared while the VM runs appear under it.
    rw="$work/Projects"
    ro="$work/Reference"
    mkdir -p "$rw" "$ro"
    echo "from the Mac" >"$rw/hello.txt"
    echo "read me" >"$ro/notes.txt"
    patch=$(jq -nc --arg rw "$rw" --arg ro "$ro" '{patch: {shares: [
        {id: "share-1", name: "Projects", hostPath: $rw, readOnly: false},
        {id: "share-2", name: "Reference", hostPath: $ro, readOnly: true}]}}')
    out=$(it_rpc "$socket" vm.settings.apply "$patch") || it_fail "vm.settings.apply failed" || return 1
    [[ $(jq -r .fields.shares <<<"$out") == applied ]] || it_fail "sharing did not apply live: $out" || return 1
    it_wait_for 10 it_agent_exec 'grep -qx "from the Mac" /mnt/vmpane/Projects/hello.txt' \
        || it_fail "the guest does not see the shared file: $(it_agent_exec 'ls -la /mnt/vmpane /mnt/vmpane/* 2>&1')" || return 1
    echo "shares-linux: folders shared live appear at /mnt/vmpane/<name>"

    # 3. 100 MB both ways, byte-identical.
    dd if=/dev/urandom of="$rw/big.bin" bs=1m count=100 2>/dev/null
    host_sum=$(shasum -a 256 "$rw/big.bin" | cut -d' ' -f1)
    start=$SECONDS
    guest_sum=$(it_agent_exec 'sha256sum /mnt/vmpane/Projects/big.bin' | cut -d' ' -f1)
    [[ $guest_sum == "$host_sum" ]] || it_fail "the guest reads different bytes" || return 1
    it_agent_exec 'head -c 104857600 /dev/urandom >/root/up.bin && cp /root/up.bin /mnt/vmpane/Projects/up.bin && sync && sha256sum /root/up.bin' \
        | cut -d' ' -f1 >"$work/up.sum" || it_fail "the guest could not write to the share" || return 1
    [[ $(shasum -a 256 "$rw/up.bin" | cut -d' ' -f1) == "$(cat "$work/up.sum")" ]] || it_fail "the Mac reads different bytes" || return 1
    echo "shares-linux: 100 MB round-trips byte-identical ($((SECONDS - start)) s both ways)"

    # 4. Read-only stays read-only.
    it_agent_exec 'grep -qx "read me" /mnt/vmpane/Reference/notes.txt' || it_fail "the read-only share is not readable" || return 1
    if it_agent_exec 'touch /mnt/vmpane/Reference/x' 2>/dev/null; then it_fail "the read-only share accepted a write"; return 1; fi
    echo "shares-linux: the read-only share refuses writes"
}
