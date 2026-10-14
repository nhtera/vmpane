# S11: which settings change while a VZ guest runs. The helper's VMPANE_TEST_PROBE_LIVE hook tries each
# runtime change on a running Linux and macOS guest; the guest must survive it. Prints the matrix
# (copied into docs/live-capabilities.md). Then vm.settings.apply must report the same split.
source "$VMPANE_ROOT/itest/lib/common.sh"
IT_SCENARIO=vz-live-probe

# The screen size (WxH pixels) of the guest behind $socket (the caller's).
guest_screen() { it_rpc "$socket" vm.screenshot '{"maxEdge": 0}' | jq -r '"\(.width)x\(.height)"'; }
guest_screen_is() { [[ $(guest_screen) == "$1" ]]; }

# Starts a clone of golden bundle $1 as $2 with one share, waits for `$3` (a readiness command), probes,
# then runs `$4` (a still-alive check). Optional: `$5`, a jq filter for the clone's config, and `$6`, a check
# that the new display size (2048 × 1280) reached the guest as it should.
probe_guest() {
    local golden=$1 name=$2 ready=$3 alive=$4 config=${5:-.} resized=${6:-true} b pid socket out offset
    b="$VMPANE_SUPPORT_DIR/VMs/$name.vmpane"
    it_clone_bundle "$golden" "$b"
    mkdir -p "$work/share-$name"
    jq --arg id "$(uuidgen)" --arg dir "$work/share-$name" \
        '.id = $id | .shares = [{id: "s1", name: "probe", hostPath: $dir, readOnly: true}] | '"$config" \
        "$b/config.json" >"$b/c.tmp" && mv "$b/c.tmp" "$b/config.json"
    out="$work/probe-$name.json"
    pid=$(VMPANE_TEST_PROBE_LIVE=$out it_start_helper "$b") || return 1
    pids+=("$pid")
    socket=$(it_socket "$b")
    it_rpc "$socket" vm.start '{"headless": true}' >/dev/null || it_fail "$name did not start" || return 1
    bundle=$b socket=$socket eval "$ready" || it_fail "$name not ready" || return 1
    offset=$(it_log_size "$b")
    touch "$out.go"
    it_wait_for 60 test -s "$out" || it_fail "$name: no probe output" || return 1
    sleep 5
    [[ $(it_state "$b") == running ]] || it_fail "$name: guest stopped after the probe" || return 1
    bundle=$b offset=$offset eval "$alive" || it_fail "$name: guest not alive after the probe" || return 1
    echo "== $name"
    jq -r 'to_entries[] | "\(.key): \(.value)"' "$out"

    local patch fields want='{"cpu.count":"nextBoot","display.heightPx":"applied","display.widthPx":"applied","network.0.mode":"applied","shares":"applied"}'
    patch=$(jq -c '{patch: {display: {widthPx: 2048, heightPx: 1280}, network: [.network[0] | .mode = "none"], shares: [], cpu: {count: 3}}}' "$b/config.json")
    fields=$(it_rpc "$socket" vm.settings.apply "$patch" | jq -cS .fields)
    [[ $fields == "$want" ]] || it_fail "$name: settings.apply reported $fields" || return 1
    [[ $(jq -r '.network[0].mode' "$b/config.json") == none ]] || it_fail "$name: settings not saved" || return 1
    [[ $(it_state "$b") == running ]] || it_fail "$name: guest stopped after settings.apply" || return 1
    socket=$socket eval "$resized" || it_fail "$name: the new display size did not reach the guest as it should" || return 1
    echo "settings.apply: $fields"
    it_rpc "$socket" vm.stop '{"mode": "force"}' >/dev/null
    it_rpc "$socket" helper.shutdown >/dev/null
    it_wait_exit "$pid"
}

scenario_run() {
    local work pids=() linux macos
    linux=$(it_golden_linux) || return 1
    macos=$(it_golden_macos) || return 1
    work=$(mktemp -d /tmp/vp-live.XXXXXX)
    export VMPANE_SUPPORT_DIR="$work/s"
    mkdir -p "$VMPANE_SUPPORT_DIR/VMs"
    trap 'set +e; for p in "${pids[@]}"; do kill -9 "$p" 2>/dev/null; done; rm -rf "$work"; true' RETURN

    # Linux: still ticking on the serial console after the changes. macOS: the screen still draws.
    # Linux at Standard scaling takes the new 2048 × 1280 in points, as at boot: 1024 × 640. Set to 2560 × 1600 it boots
    # at 1280 × 800, and its console can shrink but not grow, so the pixels themselves (which made a Linux installer's
    # text half its size) leave it at 1280 × 800.
    probe_guest "$linux" L 'it_wait_for 60 grep -q VMPANE-ITEST-READY "$bundle/logs/serial.log"' \
        'it_next_tick "$bundle" "$offset" >/dev/null' '.display += {scaling: "standard", widthPx: 2560, heightPx: 1600}' \
        'it_wait_for 20 guest_screen_is 1024x640 || { echo "L: screen $(guest_screen), not 1024x640" >&2; false; }' ||
        return 1
    probe_guest "$macos" M 'sleep 45' \
        'it_rpc "$(it_socket "$bundle")" vm.screenshot "{\"maxEdge\": 400}" | jq -e .width >/dev/null' || return 1
    return 0
}
