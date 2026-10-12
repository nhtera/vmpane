# Guest-visible VZ devices on a Linux guest (golden image probe on the serial console):
#   - nested virtualization: /dev/kvm in the guest when enabled (M3 and later), absent when off;
#   - Rosetta: the `rosetta` virtiofs tag carries the Rosetta binary when enabled (host Rosetta installed);
#   - VMPane shares: the `vmpane-shares` tag lists each share as a directory; a folder shared while the VM runs
#     (it_share_live: on a signed app in the VM window's settings, an unlocked GUI session) reaches the guest
#     (checked for a mount kept since boot and for a fresh mount).
source "$VMPANE_ROOT/itest/lib/common.sh"
IT_SCENARIO=vz-devices

# The last VMPANE-PROBE line of bundle $1 after byte offset $2 (waits up to 30 s).
probe_after() {
    it_wait_for 30 bash -c "tail -c +$(($2 + 1)) '$1/logs/serial.log' | grep -aq 'VMPANE-PROBE kvm='" || return 1
    tail -c +$(($2 + 1)) "$1/logs/serial.log" | grep -a 'VMPANE-PROBE kvm=' | tail -1 | tr -d '\r'
}

field() { sed -E "s/.* $1=([^ ]*).*/\1/" <<<"$2"; }

boot_with() {  # boot_with <name> <jq filter>: echoes "<bundle> <pid>"
    local b="$VMPANE_SUPPORT_DIR/VMs/$1.vmpane" pid
    it_clone_bundle "$golden" "$b"
    # Own id and MAC: the library re-identifies a bundle that shares them with another VM (a Finder copy).
    jq --arg id "$(uuidgen)" --arg mac "$(printf '52:54:00:%02x:%02x:%02x' $((RANDOM % 256)) $((RANDOM % 256)) $((RANDOM % 256)))" \
        ".id = \$id | .network[0].macAddress = \$mac | $2" "$b/config.json" >"$b/c.tmp" && mv "$b/c.tmp" "$b/config.json"
    pid=$(it_start_helper "$b") || return 1
    it_rpc "$(it_socket "$b")" vm.start '{"headless": true}' >/dev/null || return 1
    it_wait_for 60 grep -q VMPANE-ITEST-READY "$b/logs/serial.log" || return 1
    echo "$b $pid"
}

scenario_run() {
    local work golden pids=() b pid socket probe nested_expected=yes rosetta_expected=yes
    golden=$(it_golden_linux) || return 1
    work=$(mktemp -d /tmp/vp-dev.XXXXXX)
    export VMPANE_SUPPORT_DIR="$work/s"
    mkdir -p "$VMPANE_SUPPORT_DIR/VMs" "$work/data" "$work/more"
    echo hello >"$work/data/hello.txt"
    echo world >"$work/more/world.txt"
    trap 'set +e; for p in "${pids[@]}"; do kill -9 "$p" 2>/dev/null; done; rm -rf "$work"; true' RETURN
    # Nested virtualization needs an M3 or later; Rosetta must be installed on the host.
    sysctl -n machdep.cpu.brand_string | grep -qE 'M1|M2' && nested_expected=no
    arch -x86_64 /usr/bin/true 2>/dev/null || rosetta_expected=no

    # 1. Everything on.
    read -r b pid < <(boot_with on '.vz.rosetta = true | .vz.nestedVirtualization = true
        | .shares = [{id: "s1", name: "data", hostPath: "'"$work/data"'", readOnly: true}]') || it_fail "VM did not boot" || return 1
    pids+=("$pid")
    socket=$(it_socket "$b")
    probe=$(probe_after "$b" 0) || it_fail "no probe output" || return 1
    echo "on: $probe"
    [[ $(field kvm "$probe") == "$nested_expected" ]] || it_fail "nested virtualization: expected kvm=$nested_expected" || return 1
    [[ $(field rosetta "$probe") == "$rosetta_expected" ]] || it_fail "Rosetta: expected rosetta=$rosetta_expected" || return 1
    [[ $(field share "$probe") == "./data,./data/hello.txt," ]] || it_fail "share not visible" || return 1

    # 2. Live share change: a second share appears without a restart.
    local offset
    it_share_live "$work/more" true || return 1
    offset=$(it_log_size "$b")
    it_rpc "$socket" vm.input.text '{"text": "VMPANE-PROBE\n"}' >/dev/null
    probe=$(probe_after "$b" "$offset") || it_fail "no probe after the change" || return 1
    echo "after live change: $probe"
    [[ $(field fresh "$probe") == "./data,./data/hello.txt,./more,./more/world.txt," ]] || it_fail "new share not visible to a fresh mount" || return 1
    [[ $(field share "$probe") == "./data,./data/hello.txt,./more,./more/world.txt," ]] \
        || echo "vz-devices: note: a mount kept since boot does not show the new share (remount needed)"
    it_rpc "$socket" vm.stop '{"mode": "force"}' >/dev/null
    it_rpc "$socket" helper.shutdown >/dev/null
    it_wait_exit "$pid"

    # 3. Everything off: no /dev/kvm, no Rosetta, no shares (the share device stays, empty, for live adds).
    read -r b pid < <(boot_with off '.vz.rosetta = false | .vz.nestedVirtualization = false | .shares = []') || it_fail "VM did not boot" || return 1
    pids+=("$pid")
    probe=$(probe_after "$b" 0) || it_fail "no probe output" || return 1
    echo "off: $probe"
    [[ $probe == *"kvm=no rosetta=no share= fresh="* ]] || it_fail "devices present while off" || return 1
    it_rpc "$(it_socket "$b")" vm.stop '{"mode": "force"}' >/dev/null
    it_rpc "$(it_socket "$b")" helper.shutdown >/dev/null
    it_wait_exit "$pid"
    return 0
}
