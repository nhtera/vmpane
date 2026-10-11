# A macOS install through the helper survives an interruption:
#   1. vm.start answers within a minute while the install runs ({"installing": true}), not after it;
#   2. the helper is killed (SIGKILL) mid-install: the config keeps its install source;
#   3. a new helper's vm.start installs again (not a boot of the half-installed disk), the install finishes
#      (the config drops its source and records the machine identifier) and the installed system shows
#      Setup Assistant (headless screenshot not black).
# Skips below 30 GiB free (the install writes ~20 GiB and keeps a 5 GiB reserve).
source "$VMPANE_ROOT/itest/lib/common.sh"
IT_SCENARIO=macos-install

scenario_run() {
    local url sha ipsw work bundle pid socket out start shot lit
    (($(df -g "$HOME" | awk 'NR == 2 {print $4}') >= 30)) || { echo "macos-install: needs 30 GiB free"; return 77; }
    read -r url sha < <(awk '$1 == "macos-15.6.1-ipsw" {print $2, $3}' "$VMPANE_ROOT/itest/images.lock")
    ipsw="$HOME/Library/Caches/app.vmpane.mac/IPSW/$(basename "$url")"
    if [[ ! -f $ipsw ]]; then ipsw=$(it_image macos-15.6.1-ipsw) || return 1; fi

    work=$(cd "$(mktemp -d /tmp/vp-mi.XXXXXX)" && pwd -P)
    export VMPANE_SUPPORT_DIR="$work/s"
    mkdir -p "$VMPANE_SUPPORT_DIR/VMs"
    bundle="$VMPANE_SUPPORT_DIR/VMs/M.vmpane"
    trap 'set +e; [[ -n ${pid:-} ]] && kill -TERM "$pid" 2>/dev/null && it_wait_exit "$pid" 60; rm -rf "$work"; true' RETURN
    it_create_bundle "$bundle" macos \
        '.cpu.count = 4 | .memory.mib = 8192 | .disks[0].sizeGiB = 48 | .install = {restoreImage: "'"$ipsw"'"}'
    truncate -s 48g "$bundle/current/disk.img"

    # 1. vm.start answers while installing.
    pid=$(it_start_helper "$bundle") || return 1
    socket=$(it_socket "$bundle")
    start=$SECONDS
    out=$(it_rpc "$socket" vm.start '{"headless": true}') || it_fail "vm.start failed: $out" || return 1
    jq -e '.installing == true' <<<"$out" >/dev/null || it_fail "vm.start did not say it is installing: $out" || return 1
    ((SECONDS - start < 60)) || it_fail "vm.start took $((SECONDS - start)) s to answer" || return 1
    echo "macos-install: vm.start answered after $((SECONDS - start)) s: $out"

    # 2. Interrupt the install.
    sleep 120
    jq -e '.install.restoreImage != null' "$bundle/config.json" >/dev/null \
        || it_fail "the install finished within 2 min; nothing to interrupt" || return 1
    kill -KILL "$pid"
    it_wait_exit "$pid" 15 || it_fail "the helper survived SIGKILL" || return 1
    pid=
    jq -e '.install.restoreImage != null' "$bundle/config.json" >/dev/null \
        || it_fail "the killed install lost its source" || return 1

    # 3. A new helper installs again and finishes.
    pid=$(it_start_helper "$bundle") || return 1
    start=$SECONDS
    out=$(it_rpc "$socket" vm.start '{"headless": true}') || it_fail "vm.start after the kill failed: $out" || return 1
    jq -e '.installing == true' <<<"$out" >/dev/null || it_fail "vm.start after the kill did not install: $out" || return 1
    it_wait_for 3600 bash -c "jq -e '.install == null' '$bundle/config.json' >/dev/null" \
        || it_fail "the install did not finish within 60 min" || return 1
    jq -e '.platform.machineIdentifier != null' "$bundle/config.json" >/dev/null \
        || it_fail "the installed config has no machine identifier" || return 1
    echo "macos-install: reinstalled in $(((SECONDS - start) / 60)) min"
    it_wait_for 120 bash -c "[[ \$(/usr/bin/python3 '$VMPANE_ROOT/itest/lib/rpc.py' '$socket' vm.info | jq -r .state) == running ]]" \
        || it_fail "the installed VM is not running" || return 1
    shot="$work/shot.png"
    lit=0
    start=$SECONDS
    while ((SECONDS - start < 180)); do
        it_rpc "$socket" vm.screenshot '{"maxEdge": 800}' | jq -r .dataB64 | base64 -d >"$shot" 2>/dev/null || true
        lit=$(it_png_lit_percent "$shot" 2>/dev/null || echo 0)
        ((lit > 5)) && break
        sleep 5
    done
    ((lit > 5)) || it_fail "the installed system's screen stayed black" || return 1
    echo "macos-install: installed system on screen (${lit}% lit)"
    it_rpc "$socket" vm.stop '{"mode": "force"}' >/dev/null
    it_rpc "$socket" helper.shutdown >/dev/null || true
    it_wait_exit "$pid" 30 || true
    pid=
    return 0
}
