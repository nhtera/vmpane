# The clipboard matrix through vm.clipboard.read/write (Phase 09). A macOS guest (the golden macOS bundle with a
# user and the agent; its session helper owns the guest pasteboard): text and PNG both ways, files copied in the
# guest (vm.clipboard.read names them by their guest paths; agent.file.pull fetches them), and the VM's direction
# setting honoured. Files into the guest go by vm.files.drop (scenario dnd), not the clipboard.
# Linux and Windows guests share text with the person's pasteboard over SPICE while the window is in front;
# vm.clipboard.* do not reach them (documented): checked here on Linux, refused with a clear error.
# Sourced by scripts/itest.sh with $APP set.

source "$VMPANE_ROOT/itest/lib/common.sh"
IT_SCENARIO=clipboard-matrix

it_agent_exec() { /usr/bin/python3 "$VMPANE_ROOT/itest/lib/agent_exec.py" "$socket" "$@"; }

it_agent_session() { it_rpc "$socket" agent.status 2>/dev/null | jq -e '.connected and .session' >/dev/null; }

# Starts a helper for bundle $1 with clipboard sharing set to $2; sets pid and socket.
it_start_with_clipboard() {
    local config="$1/config.json"
    jq --arg mode "$2" '.clipboard.mode = $mode' "$config" >"$config.new" && mv "$config.new" "$config" && chmod 600 "$config"
    pid=$(it_start_helper "$1") || return 1
    socket=$(it_socket "$1")
    it_rpc "$socket" vm.start '{"headless": true}' >/dev/null || { it_fail "vm.start failed"; return 1; }
}

it_stop_helper() {
    it_rpc "$socket" vm.stop '{"mode": "force"}' >/dev/null
    it_rpc "$socket" helper.shutdown >/dev/null
    it_wait_exit "$pid" || true
    pid=
}

scenario_run() {
    local golden work bundle pid socket status=0 text got png sum out linux
    golden=$(it_golden_macos_user) || status=$?
    ((status == 0)) || return "$status"
    work=$(mktemp -d /tmp/vp-cb.XXXXXX)
    export VMPANE_SUPPORT_DIR="$work/s"
    mkdir -p "$VMPANE_SUPPORT_DIR/VMs"
    bundle="$VMPANE_SUPPORT_DIR/VMs/M.vmpane"
    it_clone_bundle "$golden" "$bundle"
    trap 'set +e; [[ -n ${pid:-} ]] && kill -9 "$pid" 2>/dev/null; rm -rf "$work"; true' RETURN

    it_start_with_clipboard "$bundle" both || return 1
    it_wait_for 180 it_agent_session || it_fail "the agent and its session did not connect" || return 1
    it_rpc "$socket" agent.status | jq -e '.caps | index("clipboard")' >/dev/null \
        || it_fail "the guest agent has no clipboard (rebuild the guest tools: guest-tools/build-macos.sh)" || return 1

    # Text, host to guest and back (non-ASCII included; the guest reads its pasteboard as the user).
    text='VMPane clipboard ✓ — host → guest'
    it_rpc "$socket" vm.clipboard.write "$(jq -n --arg t "$text" '{items: [{type: "text", text: $t}]}')" >/dev/null \
        || it_fail "vm.clipboard.write text failed" || return 1
    got=$(it_agent_exec --user 'LANG=en_US.UTF-8 pbpaste')
    [[ $got == "$text" ]] || it_fail "host → guest text arrived as '$got'" || return 1
    text='VMPane clipboard ✓ — guest → host'
    it_agent_exec --user "printf '%s' '$text' | LANG=en_US.UTF-8 pbcopy" >/dev/null || it_fail "pbcopy failed" || return 1
    got=$(it_rpc "$socket" vm.clipboard.read '{"types": ["text"]}' | jq -r '.items[] | select(.type == "text") | .text')
    [[ $got == "$text" ]] || it_fail "guest → host text arrived as '$got'" || return 1
    echo "clipboard-matrix: macOS text host → guest and guest → host (UTF-8) OK"

    # PNG both ways: the guest's screenshot as the image, compared byte for byte.
    png="$work/image.png"
    it_screenshot "$socket" "$png" 320 || it_fail "no screenshot to use as an image" || return 1
    sum=$(shasum -a 256 "$png" | cut -d' ' -f1)
    it_rpc "$socket" vm.clipboard.write "$(jq -n --arg d "$(base64 <"$png")" '{items: [{type: "png", dataB64: $d}]}')" >/dev/null \
        || it_fail "vm.clipboard.write png failed" || return 1
    out=$(it_agent_exec --user "osascript -e 'set f to open for access POSIX file \"/tmp/clip.png\" with write permission' \
        -e 'set eof f to 0' -e 'write (the clipboard as «class PNGf») to f' -e 'close access f' && shasum -a 256 /tmp/clip.png") \
        || it_fail "the guest pasteboard holds no PNG" || return 1
    [[ ${out%% *} == "$sum" ]] || it_fail "host → guest PNG changed on the way" || return 1
    it_agent_exec --user 'pbcopy </dev/null' >/dev/null  # empty the pasteboard: the next PNG must come from the guest
    it_rpc "$socket" agent.file.push "{\"hostPath\": \"$png\", \"guestPath\": \"/private/tmp/guest.png\"}" >/dev/null \
        || it_fail "push failed" || return 1
    it_agent_exec --user "osascript -e 'set the clipboard to (read (POSIX file \"/private/tmp/guest.png\") as «class PNGf»)'" >/dev/null \
        || it_fail "the guest could not put a PNG on its pasteboard" || return 1
    it_rpc "$socket" vm.clipboard.read '{"types": ["png"]}' | jq -r '.items[] | select(.type == "png") | .dataB64' \
        | base64 -d >"$work/back.png"
    [[ $(shasum -a 256 "$work/back.png" | cut -d' ' -f1) == "$sum" ]] || it_fail "guest → host PNG changed on the way" || return 1
    echo "clipboard-matrix: macOS PNG host → guest and guest → host, byte for byte"

    # Files from the guest: a file copied in the guest is named by its guest path, and fetched by it.
    it_agent_exec --user 'printf "file from the guest\n" > /private/tmp/clip-file.txt && osascript -e "set the clipboard to (POSIX file \"/private/tmp/clip-file.txt\")"' >/dev/null \
        || it_fail "the guest could not copy a file" || return 1
    got=$(it_rpc "$socket" vm.clipboard.read '{"types": ["files"]}' | jq -r '.items[] | select(.type == "files") | .files[0]')
    [[ $got == /private/tmp/clip-file.txt ]] || it_fail "the guest's copied file reads as '$got'" || return 1
    it_rpc "$socket" agent.file.pull "$(jq -n --arg g "$got" --arg h "$work/clip-file.txt" '{guestPath: $g, hostPath: $h}')" >/dev/null \
        || it_fail "cannot fetch the copied file" || return 1
    [[ $(cat "$work/clip-file.txt") == "file from the guest" ]] || it_fail "the guest's file arrived changed" || return 1
    echo "clipboard-matrix: a file copied in the macOS guest, named by its guest path and fetched"
    it_stop_helper

    # The VM's direction: host to guest only lends the guest's clipboard to nobody.
    it_start_with_clipboard "$bundle" hostToGuest || return 1
    it_wait_for 180 it_agent_session || it_fail "the agent did not reconnect" || return 1
    if out=$(it_rpc "$socket" vm.clipboard.read '{"types": ["text"]}'); then
        it_fail "vm.clipboard.read worked with sharing host to guest only: $out"
        return 1
    fi
    it_rpc "$socket" vm.clipboard.write '{"items": [{"type": "text", "text": "allowed"}]}' >/dev/null \
        || it_fail "host → guest refused with sharing host to guest only" || return 1
    echo "clipboard-matrix: sharing host to guest only refuses reading the guest's clipboard"
    it_stop_helper

    # Linux: SPICE text sharing only; vm.clipboard.* say so instead of hanging.
    linux=$(it_golden_linux) || return 1
    it_clone_bundle "$linux" "$VMPANE_SUPPORT_DIR/VMs/L.vmpane"
    it_start_with_clipboard "$VMPANE_SUPPORT_DIR/VMs/L.vmpane" both || return 1
    it_wait_for 60 grep -q VMPANE-ITEST-READY "$VMPANE_SUPPORT_DIR/VMs/L.vmpane/logs/serial.log" || it_fail "Linux did not boot" || return 1
    out=$(it_rpc "$socket" vm.clipboard.read '{"types": ["text"]}') && { it_fail "vm.clipboard.read answered on Linux: $out"; return 1; }
    [[ $out == *"macOS guests have one"* ]] || it_fail "Linux refusal is unclear: $out" || return 1
    echo "clipboard-matrix: Linux (SPICE text only) refuses vm.clipboard.* clearly; Windows likewise (documented)"
    it_stop_helper
    return 0
}
