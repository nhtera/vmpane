# Headless screenshot and synthesized keyboard input on the VZ backend (S6: C2 capture + I1 input):
# the capture is not black, and text typed through vm.input.text arrives intact in the guest
# (echoed from tty1 to the serial log): "Hello, World!" and every printable ASCII character.
source "$VMPANE_ROOT/itest/lib/common.sh"
IT_SCENARIO=vz-capture

scenario_run() {
    local work bundle pid socket
    trap 'set +e; [[ -n ${pid:-} ]] && kill -9 "$pid" 2>/dev/null; rm -rf "${work:-/nonexistent}"; true' RETURN
    it_boot_linux_clone || return 1
    sleep 2  # the tty1 reader starts with the other units

    local shot="$work/shot.png" lit
    it_rpc "$socket" vm.screenshot '{"maxEdge": 1280}' | jq -r .dataB64 | base64 -d >"$shot" || it_fail "no screenshot" || return 1
    lit=$(it_png_lit_percent "$shot")
    ((lit > 0)) || it_fail "headless screenshot is black" || return 1
    echo "vz-capture: screenshot $(sips -g pixelWidth -g pixelHeight "$shot" | awk '/pixel/ {printf "%s ", $2}')(${lit}% lit)"

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

    it_rpc "$socket" vm.stop '{"mode": "force"}' >/dev/null
    it_rpc "$socket" helper.shutdown >/dev/null
    it_wait_exit "$pid"
    pid=
    return 0
}
