# Windows 11 on the QEMU backend: clone the golden bundle, boot headless through the helper (sandboxed QEMU
# and swtpm from the runtime copy), wait for the desktop on screenshots (target < 90 s), check the TPM and
# the children record, then an ACPI shutdown that Windows completes by itself.
# Sourced by scripts/itest.sh with $APP set.

source "$VMPANE_ROOT/itest/lib/common.sh"
IT_SCENARIO=win-boot

scenario_run() {
    local golden work bundle pid socket start elapsed children status
    golden=$(it_golden_windows) || { status=$?; return "$status"; }
    work=$(cd "$(mktemp -d /tmp/vp-wb.XXXXXX)" && pwd -P)
    export VMPANE_SUPPORT_DIR="$work/s"
    mkdir -p "$VMPANE_SUPPORT_DIR/VMs"
    bundle="$VMPANE_SUPPORT_DIR/VMs/W.vmpane"
    it_clone_bundle "$golden" "$bundle"
    trap 'set +e; [[ -n ${pid:-} ]] && kill -TERM "$pid" 2>/dev/null && it_wait_exit "$pid" 150; rm -rf "$work"; true' RETURN

    pid=$(it_start_helper "$bundle") || return 1
    socket=$(it_socket "$bundle")
    start=$SECONDS
    it_rpc "$socket" vm.start '{"headless": true}' >/dev/null || it_fail "vm.start failed" || return 1
    it_wait_windows_desktop "$socket" 90 || it_fail "no desktop within 90 s" || return 1
    elapsed=$((SECONDS - start))
    echo "win-boot: desktop after ${elapsed} s (target < 90 s)"
    [[ $(it_rpc "$socket" vm.info | jq -r .state) == running ]] || it_fail "state is not running" || return 1

    # swtpm and QEMU are recorded children, both running from the runtime copy under sandbox-exec's exec.
    children=$(jq -r .process.pid "$VMPANE_SUPPORT_DIR/run/"*.children | paste -sd, -)
    [[ $(ps -o comm= -p "$children" | xargs -n1 basename | sort | paste -sd, -) == qemu-system-aarch64,swtpm ]] \
        || it_fail "children are not QEMU and swtpm: $(ps -o comm= -p "$children")" || return 1
    [[ -s $bundle/current/aux/tpm/tpm2-00.permall ]] || it_fail "no TPM state in the bundle" || return 1

    it_rpc "$socket" vm.stop '{"mode": "graceful"}' >/dev/null || it_fail "vm.stop failed" || return 1
    it_wait_for 150 bash -c "[[ \$(/usr/bin/python3 '$VMPANE_ROOT/itest/lib/rpc.py' '$socket' vm.info | jq -r .state) == stopped ]]" \
        || it_fail "Windows did not shut down within 150 s" || return 1
    echo "win-boot: shut down $((SECONDS - start - elapsed)) s after the power button"
    ! ps -p "$children" >/dev/null || it_fail "QEMU or swtpm still running after the shutdown" || return 1
    it_rpc "$socket" helper.shutdown >/dev/null
    it_wait_exit "$pid" 30 || true
    pid=
    return 0
}
