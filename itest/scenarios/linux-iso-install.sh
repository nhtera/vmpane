# Linux install from an ISO on the VZ backend:
#   1. a blank VM with the catalog's Debian netinst (sha256-checked) as install media boots the
#      installer (screen not black);
#   2. after the install (a partitioned disk + the OS boot entry in the firmware), the installer's reboot
#      happens in place (VZ resets Linux guests without stopping the VM) and the installed system boots
#      ahead of the still-attached ISO; at the next stop the helper detaches the media.
# Step 2 uses the golden Linux clone as "the installed system" and its VMPANE-REBOOT/-POWEROFF triggers.
source "$VMPANE_ROOT/itest/lib/common.sh"
IT_SCENARIO=linux-iso-install

# Path of the catalog image $1, downloaded once into ~/VMPaneItest/downloads and sha256-checked.
iso_from_catalog() {
    local entry url sha file
    entry=$(jq -c --arg id "$1" '.images[] | select(.id == $id)' \
        "$VMPANE_ROOT/Packages/VMPaneKit/Sources/VMPaneHost/Install/Resources/linux-catalog.json")
    url=$(jq -r .url <<<"$entry")
    sha=$(jq -r .sha256 <<<"$entry")
    file="$HOME/VMPaneItest/downloads/$(basename "$url")"
    if [[ ! -f $file || $(shasum -a 256 "$file" | awk '{print $1}') != "$sha" ]]; then
        mkdir -p "$(dirname "$file")"
        curl -fsSL --retry 3 -o "$file.partial" "$url" || return 1
        [[ $(shasum -a 256 "$file.partial" | awk '{print $1}') == "$sha" ]] || { echo "sha256 mismatch: $url" >&2; return 1; }
        mv "$file.partial" "$file"
    fi
    echo "$file"
}

install_media() {  # jq filter: attach $iso as install media
    echo '.removable += [{id: "install", path: "'"$1"'", bus: "usb"}] | .install = {media: "install"}'
}

scenario_run() {
    local work iso pids=() b pid socket shot lit start
    iso=$(iso_from_catalog debian-13.7-netinst) || { it_fail "cannot get the Debian netinst ISO"; return 1; }
    work=$(mktemp -d /tmp/vp-iso.XXXXXX)
    export VMPANE_SUPPORT_DIR="$work/s"
    mkdir -p "$VMPANE_SUPPORT_DIR/VMs"
    trap 'set +e; for p in "${pids[@]}"; do kill -9 "$p" 2>/dev/null; done; rm -rf "$work"; true' RETURN

    # 1. Blank disk + ISO: the installer comes up.
    b="$VMPANE_SUPPORT_DIR/VMs/I.vmpane"
    it_create_bundle "$b" linux "$(install_media "$iso")"
    mkfile -n 8g "$b/current/disk.img"
    pid=$(it_start_helper "$b") || return 1
    pids+=("$pid")
    socket=$(it_socket "$b")
    it_rpc "$socket" vm.start '{"headless": true}' >/dev/null || it_fail "VM with the ISO did not start" || return 1
    shot="$work/shot.png"
    lit=0
    start=$SECONDS
    while ((SECONDS - start < 90)); do
        it_rpc "$socket" vm.screenshot '{"maxEdge": 800}' | jq -r .dataB64 | base64 -d >"$shot" 2>/dev/null || true
        lit=$(it_png_lit_percent "$shot" 2>/dev/null || echo 0)
        ((lit > 3)) && break
        sleep 3
    done
    ((lit > 3)) || it_fail "the installer never drew anything" || return 1
    echo "linux-iso-install: installer menu on screen after $((SECONDS - start)) s (${lit}% lit)"
    # Enter boots the installer kernel from the ISO: the screen leaves the boot menu.
    it_rpc "$socket" vm.input.text '{"text": "\n"}' >/dev/null
    local changed=false
    start=$SECONDS
    while ((SECONDS - start < 90)); do
        sleep 5
        it_rpc "$socket" vm.screenshot '{"maxEdge": 800}' | jq -r .dataB64 | base64 -d >"$work/next.png" 2>/dev/null || true
        if ! cmp -s "$shot" "$work/next.png" && (($(it_png_lit_percent "$work/next.png" 2>/dev/null || echo 0) > 3)); then
            changed=true
            break
        fi
    done
    $changed || it_fail "the installer kernel did not start from the ISO" || return 1
    echo "linux-iso-install: installer kernel running after $((SECONDS - start)) s"
    it_rpc "$socket" vm.stop '{"mode": "force"}' >/dev/null
    [[ $(jq -r '.install.media' "$b/config.json") == install ]] || it_fail "a requested stop removed the media" || return 1
    it_rpc "$socket" helper.shutdown >/dev/null
    it_wait_exit "$pid"

    # 2. The installer's reboot (in place), then the guest's power-off: media detached for the next start.
    local golden ready
    golden=$(it_golden_linux) || return 1
    b="$VMPANE_SUPPORT_DIR/VMs/G.vmpane"
    it_clone_bundle "$golden" "$b"
    jq "$(install_media "$iso")" "$b/config.json" >"$b/c.tmp" && mv "$b/c.tmp" "$b/config.json"
    pid=$(it_start_helper "$b") || return 1
    pids+=("$pid")
    socket=$(it_socket "$b")
    it_rpc "$socket" vm.start '{"headless": true}' >/dev/null || it_fail "golden with media did not start" || return 1
    it_wait_for 60 grep -q VMPANE-ITEST-READY "$b/logs/serial.log" || it_fail "installed system did not boot ahead of the ISO" || return 1
    it_rpc "$socket" vm.input.text '{"text": "VMPANE-REBOOT\n"}' >/dev/null
    it_wait_for 90 bash -c "[[ \$(grep -a -c VMPANE-ITEST-READY '$b/logs/serial.log') -ge 2 ]]" \
        || it_fail "no boot after the guest's reboot" || return 1
    [[ $(it_state "$b") == running ]] || it_fail "the reboot stopped the VM (expected an in-place reset)" || return 1
    it_rpc "$socket" vm.input.text '{"text": "VMPANE-POWEROFF\n"}' >/dev/null
    it_wait_for 60 bash -c "[[ \$(/usr/bin/python3 '$VMPANE_ROOT/itest/lib/rpc.py' '$socket' vm.info | jq -r .state) == stopped ]]" \
        || it_fail "the guest did not power off" || return 1
    it_wait_for 10 bash -c "[[ \$(jq -r '.install // \"none\"' '$b/config.json') == none ]]" || it_fail "install media not detached" || return 1
    [[ $(jq '[.removable[] | select(.id == "install")] | length' "$b/config.json") == 0 ]] || it_fail "media still listed" || return 1
    ready=$(grep -a -c VMPANE-ITEST-READY "$b/logs/serial.log")
    it_rpc "$socket" vm.start '{"headless": true}' >/dev/null || it_fail "start without media failed" || return 1
    it_wait_for 60 bash -c "[[ \$(grep -a -c VMPANE-ITEST-READY '$b/logs/serial.log') -gt $ready ]]" \
        || it_fail "the installed system did not boot without the media" || return 1
    echo "linux-iso-install: in-place reboot kept the VM running; media detached at power-off; boots without it"
    it_rpc "$socket" vm.stop '{"mode": "force"}' >/dev/null
    it_rpc "$socket" helper.shutdown >/dev/null
    it_wait_exit "$pid"
    return 0
}
