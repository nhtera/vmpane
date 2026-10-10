# Headless screenshot and synthesized keyboard input on the VZ backend (S6: C2 capture + I1 input):
# the capture is not black, and text typed through vm.input.text arrives intact in the guest
# (echoed from tty1 to the serial log): "Hello, World!" and every printable ASCII character.
# Absolute pointer: clicks through vm.input.pointer land at the same relative position in the guest's
# evdev device (reported on the serial log).
source "$VMPANE_ROOT/itest/lib/common.sh"
IT_SCENARIO=vz-capture

scenario_run() {
    local work bundle pid socket
    trap 'set +e; [[ -n ${pid:-} ]] && kill -9 "$pid" 2>/dev/null; rm -rf "${work:-/nonexistent}"; true' RETURN
    it_boot_linux_clone || return 1
    sleep 2  # the tty1 reader starts with the other units

    local shot="$work/shot.png" lit
    it_rpc "$socket" vm.screenshot '{"maxEdge": 1280}' | jq -r .dataB64 | base64 -d >"$shot" || it_fail "no screenshot" || return 1
    lit=$(it_png_lit_pixels "$shot")
    ((lit > 100)) || it_fail "headless screenshot is black" || return 1
    echo "vz-capture: screenshot $(sips -g pixelWidth -g pixelHeight "$shot" | awk '/pixel/ {printf "%s ", $2}')($lit lit pixels)"

    local text='Hello, World!'
    it_rpc "$socket" vm.input.text "$(jq -n --arg t "$text"$'\n' '{text: $t}')" >/dev/null || it_fail "vm.input.text failed" || return 1
    it_wait_for 10 grep -aqF "VMPANE-TYPED $text" "$bundle/logs/serial.log" \
        || { it_fail "typed text did not arrive: $(grep -a VMPANE-TYPED "$bundle/logs/serial.log" | tail -1)"; return 1; }

    # Every printable ASCII character (US keymap with Shift).
    local ascii
    ascii=$(/usr/bin/python3 -c 'print("".join(chr(c) for c in range(0x20, 0x7F)), end="")')
    it_rpc "$socket" vm.input.text "$(jq -n --arg t "$ascii"$'\n' '{text: $t}')" >/dev/null || it_fail "ASCII typing failed" || return 1
    it_wait_for 10 grep -aqF "VMPANE-TYPED $ascii" "$bundle/logs/serial.log" \
        || { it_fail "ASCII did not arrive intact: $(grep -a VMPANE-TYPED "$bundle/logs/serial.log" | tail -1)"; return 1; }
    echo "vz-capture: typed text and all printable ASCII arrived intact"

    # Absolute pointer: click at three points; the guest sees the same fraction of its axis range (±2%).
    local size width height device max_x max_y px py line gx gy
    size=$(it_rpc "$socket" vm.screenshot '{"maxEdge": 0}' | jq -r '"\(.width) \(.height)"')
    read -r width height <<<"$size"
    device=$(grep -a VMPANE-POINTER-DEVICE "$bundle/logs/serial.log" | head -1 | tr -d '\r')
    [[ -n $device ]] || it_fail "no absolute pointing device in the guest" || return 1
    max_x=$(sed -E 's/.*max=([0-9]+),.*/\1/' <<<"$device")
    max_y=$(sed -E 's/.*max=[0-9]+,([0-9]+).*/\1/' <<<"$device")
    for point in "0.1 0.1" "0.5 0.5" "0.9 0.8"; do
        read -r fx fy <<<"$point"
        px=$(awk "BEGIN {printf \"%d\", $fx * $width}")
        py=$(awk "BEGIN {printf \"%d\", $fy * $height}")
        local offset
        offset=$(it_log_size "$bundle")
        it_rpc "$socket" vm.input.pointer "{\"x\": $px, \"y\": $py, \"buttons\": 0}" >/dev/null
        it_rpc "$socket" vm.input.pointer "{\"x\": $px, \"y\": $py, \"buttons\": 1}" >/dev/null
        it_rpc "$socket" vm.input.pointer "{\"x\": $px, \"y\": $py, \"buttons\": 0}" >/dev/null
        it_wait_for 10 bash -c "tail -c +$((offset + 1)) '$bundle/logs/serial.log' | grep -aq 'VMPANE-POINTER button=0 down=1'" \
            || it_fail "no click reached the guest at ($px, $py)" || return 1
        line=$(tail -c +$((offset + 1)) "$bundle/logs/serial.log" | grep -a 'VMPANE-POINTER button=0 down=1' | head -1 | tr -d '\r')
        gx=$(sed -E 's/.* x=([0-9]+).*/\1/' <<<"$line")
        gy=$(sed -E 's/.* y=([0-9]+).*/\1/' <<<"$line")
        awk "BEGIN {exit !(($gx / $max_x - $fx) ^ 2 < 0.0004 && ($gy / $max_y - $fy) ^ 2 < 0.0004)}" \
            || it_fail "click at ($px, $py) of ${width}x$height arrived at ($gx, $gy) of ($max_x, $max_y)" || return 1
    done
    # Right (bit 1) and middle (bit 2) buttons arrive as BTN_RIGHT and BTN_MIDDLE.
    for mask in 2 4; do
        offset=$(it_log_size "$bundle")
        it_rpc "$socket" vm.input.pointer "{\"x\": $px, \"y\": $py, \"buttons\": $mask}" >/dev/null
        it_rpc "$socket" vm.input.pointer "{\"x\": $px, \"y\": $py, \"buttons\": 0}" >/dev/null
        it_wait_for 10 bash -c "tail -c +$((offset + 1)) '$bundle/logs/serial.log' | grep -aq 'VMPANE-POINTER button=$((mask / 2)) down=1'" \
            || it_fail "button mask $mask did not reach the guest" || return 1
    done
    echo "vz-capture: absolute pointer clicks land where sent (${width}x$height, guest range ${max_x}x$max_y); right and middle buttons too"

    it_rpc "$socket" vm.stop '{"mode": "force"}' >/dev/null
    it_rpc "$socket" helper.shutdown >/dev/null
    it_wait_exit "$pid"
    pid=
    return 0
}
