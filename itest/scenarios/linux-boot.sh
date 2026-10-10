# Linux guest on the VZ backend: clone the golden bundle, boot headless through the helper, wait for the
# ready marker on the serial console (≤ 60 s; target < 20 s), then an ACPI shutdown.
# Sourced by scripts/itest.sh with $APP set.

source "$VMPANE_ROOT/itest/lib/common.sh"
IT_SCENARIO=linux-boot

scenario_run() {
    local golden work bundle pid socket start elapsed
    golden=$(it_golden_linux) || return 1
    work=$(mktemp -d /tmp/vp-lb.XXXXXX)
    export VMPANE_SUPPORT_DIR="$work/s"
    mkdir -p "$VMPANE_SUPPORT_DIR/VMs"
    bundle="$VMPANE_SUPPORT_DIR/VMs/L.vmpane"
    it_clone_bundle "$golden" "$bundle"
    trap 'set +e; [[ -n ${pid:-} ]] && kill -9 "$pid" 2>/dev/null; rm -rf "$work"; true' RETURN

    pid=$(it_start_helper "$bundle") || return 1
    socket=$(it_socket "$bundle")
    start=$SECONDS
    it_rpc "$socket" vm.start '{"headless": true}' >/dev/null || it_fail "vm.start failed" || return 1
    it_wait_for 60 grep -q VMPANE-ITEST-READY "$bundle/logs/serial.log" \
        || it_fail "no ready marker within 60 s" || return 1
    elapsed=$((SECONDS - start))
    echo "linux-boot: ready after ${elapsed} s (target < 20 s)"
    [[ $(it_rpc "$socket" vm.info | jq -r .state) == running ]] || it_fail "state is not running" || return 1

    it_rpc "$socket" vm.stop '{"mode": "graceful"}' >/dev/null || it_fail "vm.stop failed" || return 1
    it_wait_for 60 bash -c "[[ \$(/usr/bin/python3 '$VMPANE_ROOT/itest/lib/rpc.py' '$socket' vm.info | jq -r .state) == stopped ]]" \
        || it_fail "guest did not shut down within 60 s" || return 1
    it_rpc "$socket" helper.shutdown >/dev/null
    it_wait_exit "$pid" || true
    pid=
    return 0
}
