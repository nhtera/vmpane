# macOS guest on the VZ backend: a clone of the golden bundle boots headless to Setup Assistant
# (headless screenshot not black), and the concurrent macOS-guest limit is measured (Apple: 2).
source "$VMPANE_ROOT/itest/lib/common.sh"
IT_SCENARIO=macos-boot

scenario_run() {
    local golden work pids=() shot lit
    golden=$(it_golden_macos) || return 1
    work=$(mktemp -d /tmp/vp-mac.XXXXXX)
    export VMPANE_SUPPORT_DIR="$work/s"
    mkdir -p "$VMPANE_SUPPORT_DIR/VMs"
    trap 'set +e; for p in "${pids[@]}"; do kill -TERM "$p" 2>/dev/null; done; for p in "${pids[@]}"; do it_wait_exit "$p" 40; done; rm -rf "$work"; true' RETURN

    local bundles=()
    for n in 1 2 3; do
        local b="$VMPANE_SUPPORT_DIR/VMs/M$n.vmpane"
        it_clone_bundle "$golden" "$b"
        # Each clone needs its own identity: open it through the library (Finder-copy rule) by giving it a new id here.
        jq --arg id "$(uuidgen)" --arg mac "$(printf '52:54:00:%02x:%02x:%02x' $((RANDOM % 256)) $((RANDOM % 256)) $n)" \
            '.id = $id | .network[0].macAddress = $mac | .memory.mib = 4096' "$b/config.json" >"$b/c.tmp" && mv "$b/c.tmp" "$b/config.json"
        bundles+=("$b")
    done

    # 1. Boot one, headless: Setup Assistant on screen within 90 s.
    local first=${bundles[0]} socket
    pids+=("$(it_start_helper "$first")")
    socket=$(it_socket "$first")
    local start=$SECONDS
    it_rpc "$socket" vm.start '{"headless": true}' >/dev/null || it_fail "macOS guest did not start" || return 1
    shot="$work/shot.png"
    lit=0
    while ((SECONDS - start < 90)); do
        it_rpc "$socket" vm.screenshot '{"maxEdge": 800}' | jq -r .dataB64 | base64 -d >"$shot" 2>/dev/null || true
        lit=$(it_png_lit_percent "$shot" 2>/dev/null || echo 0)
        ((lit > 5)) && break
        sleep 3
    done
    ((lit > 5)) || it_fail "headless screenshot stayed black" || return 1
    echo "macos-boot: display up after $((SECONDS - start)) s (${lit}% lit)"

    # 2. Concurrency: a second macOS guest starts; record what the third does.
    pids+=("$(it_start_helper "${bundles[1]}")")
    it_rpc "$(it_socket "${bundles[1]}")" vm.start '{"headless": true}' >/dev/null || it_fail "second macOS guest did not start" || return 1
    pids+=("$(it_start_helper "${bundles[2]}")")
    local third
    if third=$(it_rpc "$(it_socket "${bundles[2]}")" vm.start '{"headless": true}'); then
        echo "macos-boot: a third macOS guest started too (limit > 2 on this host)"
    else
        echo "macos-boot: third macOS guest refused: $(jq -r .message <<<"$third" | cut -c1-160)"
    fi
    for b in "${bundles[@]}"; do it_rpc "$(it_socket "$b")" vm.stop '{"mode": "force"}' >/dev/null 2>&1 || true; done
    return 0
}
