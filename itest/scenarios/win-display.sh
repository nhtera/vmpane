# The Windows display through the helper's SPICE client (CocoaSpice on the SPICE libraries the helper embeds):
# the client renders the desktop at the size QEMU shows, and reconnects to the new QEMU after suspend and
# resume. The helper writes what the SPICE client has (VMPANE_TEST_SPICE_CAPTURE) each time the VM runs.
# Resize and clipboard need spice-vdagent in the guest (Phase 06).
source "$VMPANE_ROOT/itest/lib/common.sh"
IT_SCENARIO=win-display

scenario_run() {
    local golden work bundle pid socket status capture qemu_size spice_size lit result
    golden=$(it_golden_windows) || { status=$?; return "$status"; }
    work=$(cd "$(mktemp -d /tmp/vp-wd.XXXXXX)" && pwd -P)
    export VMPANE_SUPPORT_DIR="$work/s"
    mkdir -p "$VMPANE_SUPPORT_DIR/VMs"
    bundle="$VMPANE_SUPPORT_DIR/VMs/W.vmpane"
    it_clone_bundle "$golden" "$bundle"
    trap 'set +e; [[ -n ${pid:-} ]] && kill -TERM "$pid" 2>/dev/null && it_wait_exit "$pid" 150; rm -rf "$work"; true' RETURN
    capture=$work/spice.png
    pid=$(VMPANE_TEST_SPICE_CAPTURE=$capture it_start_helper "$bundle") || return 1
    socket=$(it_socket "$bundle")
    it_rpc "$socket" vm.start '{"headless": true}' >/dev/null || it_fail "vm.start failed" || return 1
    it_wait_windows_desktop "$socket" 90 || it_fail "no desktop" || return 1

    spice_desktop() {  # waits for the SPICE capture to show the desktop; checks its size against QEMU's
        it_wait_for 60 bash -c "[[ -s '$capture' ]] && (( \$(source '$VMPANE_ROOT/itest/lib/common.sh'; it_png_lit_percent '$capture') >= 40 ))" \
            || { it_fail "the SPICE client did not render the desktop (capture: $(ls -l "$capture" 2>&1))"; return 1; }
        qemu_size=$(it_rpc "$socket" vm.screenshot '{"maxEdge": 8192}' | jq -r '"\(.width)x\(.height)"')
        spice_size=$(sips -g pixelWidth -g pixelHeight "$capture" | awk '/pixelWidth/ {w=$2} /pixelHeight/ {h=$2} END {print w "x" h}')
        [[ $spice_size == "$qemu_size" ]] || { it_fail "SPICE shows $spice_size, QEMU $qemu_size"; return 1; }
        lit=$(it_png_lit_percent "$capture")
        echo "win-display: SPICE client renders the desktop at $spice_size ($lit% lit)"
    }
    spice_desktop || return 1

    # Suspend and resume start a new QEMU: the SPICE session must follow it.
    rm -f "$capture"
    it_rpc "$socket" vm.suspend >/dev/null || it_fail "vm.suspend failed" || return 1
    result=$(it_rpc "$socket" vm.start '{"headless": true}') || it_fail "start after suspend failed: $result" || return 1
    spice_desktop || return 1

    it_rpc "$socket" vm.stop '{"mode": "graceful"}' >/dev/null
    it_wait_for 150 bash -c "[[ \$(/usr/bin/python3 '$VMPANE_ROOT/itest/lib/rpc.py' '$socket' vm.info | jq -r .state) == stopped ]]"
    it_rpc "$socket" helper.shutdown >/dev/null
    it_wait_exit "$pid" 30 || true
    pid=
    return 0
}
