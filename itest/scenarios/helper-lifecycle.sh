# Helper lifecycle with the real helper binary (no app): socket + vm.info latency, single instance,
# kill -9 recovery with an orphaned child, Finder-duplicate identity, clean shutdown.
# Sourced by scripts/itest.sh with $APP set. Uses a throwaway support directory, never the user's library.

it_rpc() { /usr/bin/python3 "$VMPANE_ROOT/itest/lib/rpc.py" "$@"; }

it_fail() {
    echo "helper-lifecycle: $*" >&2
    return 1
}

# Creates a minimal valid bundle (config v1, generation, directories) at $1.
it_create_bundle() {
    local bundle=$1 id mac
    id=$(uuidgen)
    mac=$(printf '52:54:00:%02x:%02x:%02x' $((RANDOM % 256)) $((RANDOM % 256)) $((RANDOM % 256)))
    mkdir -p "$bundle/current/aux" "$bundle/current/state" "$bundle/snapshots" "$bundle/logs"
    chmod -R 700 "$bundle"
    jq -n --arg id "$id" --arg mac "$mac" '{
        schemaVersion: 1, id: $id, name: "itest", os: "linux", backend: "vz",
        cpu: {count: 2}, memory: {mib: 2048, balloon: true},
        display: {widthPx: 1280, heightPx: 800, ppi: 144, autoResize: true, scaling: "retina"},
        disks: [{id: "root", file: "current/disk.img", format: "raw", sizeGiB: 8, bus: "virtio"}],
        removable: [], platform: {}, network: [{id: "nic0", mode: "nat", macAddress: $mac}],
        portForwards: [], shares: [], audio: {output: true, input: false},
        clipboard: {mode: "both", allowWithAgents: false}, vz: {rosetta: false, nestedVirtualization: false},
        agent: {transport: "auto"},
        mcp: {policy: "off", confirmExec: true, autoSnapshot: true, auditTypedText: false},
        ui: {closeAction: "keepRunning"}}' >"$bundle/config.json"
    jq -n --arg gen "$(uuidgen)" '{schemaVersion: 1, generationId: $gen}' >"$bundle/current/generation.json"
    chmod 600 "$bundle/config.json" "$bundle/current/generation.json"
}

it_wait_for() {  # it_wait_for <seconds> <test command…>
    local deadline=$((SECONDS + $1))
    shift
    until "$@"; do
        ((SECONDS < deadline)) || return 1
        sleep 0.1
    done
}

it_sid() { jq -r .id "$1/config.json" | tr 'A-F' 'a-f' | cut -c1-8; }

scenario_run() {
    local helper="$APP/Contents/Helpers/VMPaneVM.app/Contents/MacOS/VMPaneVM"
    local work
    work=$(mktemp -d /tmp/vp-it.XXXXXX)  # short: socket paths are limited to 104 bytes
    export VMPANE_SUPPORT_DIR="$work/s"
    local bundle="$VMPANE_SUPPORT_DIR/VMs/T.vmpane"
    mkdir -p "$VMPANE_SUPPORT_DIR/VMs"
    it_create_bundle "$bundle"
    local sid run="$VMPANE_SUPPORT_DIR/run"
    sid=$(it_sid "$bundle")
    local pids=()
    # Cleanup kills only processes this scenario started (helpers and the dummy children they recorded).
    trap 'set +e
          for f in "$run"/*.children; do [[ -f $f ]] && jq -r .process.pid "$f" | xargs kill -9 2>/dev/null; done
          for p in "${pids[@]}"; do kill -9 "$p" 2>/dev/null; done
          rm -rf "$work"
          true' RETURN

    # 1. Start with a dummy child holding the lock; the socket appears; vm.info is fast.
    VMPANE_TEST_DUMMY_CHILD=1 "$helper" --vm "$bundle" --headless &
    local first=$!
    pids+=("$first")
    it_wait_for 10 test -S "$run/$sid.sock" || it_fail "no socket after 10 s" || return 1
    local info latency
    info=$(it_rpc "$run/$sid.sock" vm.info) || it_fail "vm.info failed: $info" || return 1
    [[ $(jq -r .state <<<"$info") == stopped ]] || it_fail "unexpected state: $info" || return 1
    # The documented debugging path: one line through nc, which half-closes after sending.
    nc -U "$run/$sid.sock" <<<'{"jsonrpc":"2.0","id":1,"method":"vm.info"}' | jq -e '.result.state == "stopped"' >/dev/null \
        || it_fail "vm.info through nc -U got no answer" || return 1
    latency=$(it_rpc "$run/$sid.sock" vm.info --repeat 20)
    echo "vm.info median ${latency} ms"
    awk -v l="$latency" 'BEGIN { exit !(l < 50) }' || it_fail "vm.info took ${latency} ms (limit 50)" || return 1

    # 2. A second helper for the same bundle exits 75.
    local status=0
    "$helper" --vm "$bundle" --headless || status=$?
    [[ $status == 75 ]] || it_fail "second helper exited $status, expected 75" || return 1

    # 3. kill -9 with an orphaned child, immediate relaunch (no app): the old child is reaped first.
    local old_child
    old_child=$(jq -r .process.pid "$run/$sid.children")
    kill -0 "$old_child" || it_fail "dummy child not running" || return 1
    kill -9 "$first"
    pids+=("$old_child")  # in case the relaunch fails to reap it
    VMPANE_TEST_DUMMY_CHILD=1 "$helper" --vm "$bundle" --headless &
    local second=$!
    pids+=("$second")
    it_wait_for 10 test -S "$run/$sid.sock" || it_fail "no socket after relaunch" || return 1
    it_wait_for 5 bash -c "jq -e '.process.pid == $second' '$run/$sid.pid' >/dev/null" || it_fail "pid file not rewritten" || return 1
    ! kill -0 "$old_child" 2>/dev/null || it_fail "old child $old_child survived the relaunch" || return 1
    [[ $(wc -l <"$run/$sid.children" | tr -d ' ') == 1 ]] || it_fail "expected exactly one child set" || return 1
    it_rpc "$run/$sid.sock" vm.info >/dev/null || it_fail "relaunched helper does not answer" || return 1

    # 4. A Finder-style duplicate gets a new identity and its own socket.
    cp -Rp "$bundle" "$VMPANE_SUPPORT_DIR/VMs/T copy.vmpane"
    "$helper" --vm "$VMPANE_SUPPORT_DIR/VMs/T copy.vmpane" --headless &
    pids+=("$!")
    local copy_sid
    it_wait_for 10 bash -c "[[ \$(jq -r .id '$VMPANE_SUPPORT_DIR/VMs/T copy.vmpane/config.json' | tr A-F a-f | cut -c1-8) != $sid ]]" \
        || it_fail "duplicate kept the original id" || return 1
    copy_sid=$(it_sid "$VMPANE_SUPPORT_DIR/VMs/T copy.vmpane")
    it_wait_for 10 test -S "$run/$copy_sid.sock" || it_fail "duplicate has no socket of its own" || return 1
    [[ $(jq -r '.network[0].macAddress' "$bundle/config.json") != $(jq -r '.network[0].macAddress' "$VMPANE_SUPPORT_DIR/VMs/T copy.vmpane/config.json") ]] \
        || it_fail "duplicate kept the original MAC" || return 1
    test -S "$run/$sid.sock" || it_fail "the original's socket disappeared" || return 1

    # 5. helper.shutdown: exits 0, child reaped, run files removed.
    local new_child
    new_child=$(jq -r .process.pid "$run/$sid.children")
    pids+=("$new_child")
    it_rpc "$run/$sid.sock" helper.shutdown >/dev/null || it_fail "helper.shutdown failed" || return 1
    status=0
    wait "$second" || status=$?
    [[ $status == 0 ]] || it_fail "helper exited $status after helper.shutdown" || return 1
    ! kill -0 "$new_child" 2>/dev/null || it_fail "child survived shutdown" || return 1
    for f in "$sid.sock" "$sid.pid" "$sid.children"; do
        [[ ! -e "$run/$f" ]] || it_fail "run/$f left behind" || return 1
    done
    it_rpc "$run/$copy_sid.sock" helper.shutdown >/dev/null
    return 0
}
