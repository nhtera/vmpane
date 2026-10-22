# Ubuntu Desktop from its cloud image with no clicks (Phase 04's Desktop option), then on that GNOME desktop what
# Phase 03 does for Linux (slow lane: the first boot installs the desktop, 10+ min, network-bound):
#   - cloud-init installs ubuntu-desktop-minimal, the guest tools, GDM automatic login, and restarts once; the user's
#     session helper then connects (a signed-in GNOME session; session.state unlocked);
#   - vm_exec desktop opens a GNOME app (Calculator, else Text Editor, Characters or Loupe) and the kill switch closes it;
#   - logged out to GDM's login screen (session.state greeter), vm_sign_in signs in with the kept password;
#   - a full-resolution GNOME screenshot lands in itest/results/linux-cloud-desktop-gnome.png (an OCR fixture).
# Unsigned apps only (the kept password is VMPane's dev store). Sourced by scripts/itest.sh with $APP set.

source "$VMPANE_ROOT/itest/lib/common.sh"
source "$VMPANE_ROOT/itest/scenarios/desktop-sign-in.sh"
IT_SCENARIO=linux-cloud-desktop

scenario_run() {
    local image work bundle pid socket cli="$APP/Contents/Helpers/vmpane" password=vmpane-itest-desktop started
    it_signed && { echo "linux-cloud-desktop: skipped on a signed app"; return 77; }
    image=$(jq -r '.images[] | select(.kind == "cloudImage" and .distro == "ubuntu") | .id' \
        "$VMPANE_ROOT/Packages/VMPaneKit/Sources/VMPaneHost/Install/Resources/linux-catalog.json")
    work=$(mktemp -d /tmp/vp-cdesk.XXXXXX)
    export VMPANE_SUPPORT_DIR="$work/s"
    DSI_TRANSCRIPT="$work/transcript.jsonl"
    mkdir -p "$VMPANE_SUPPORT_DIR/VMs" "$HOME/VMPaneItest/cloud"
    trap 'set +e; [[ -n ${pid:-} ]] && kill -TERM "$pid" 2>/dev/null && it_wait_exit "$pid" 60; rm -rf "$work"; trap - RETURN; true' RETURN
    bundle=$(printf '%s' "$password" | "$VMPANE_ITEST_POLICY" create-cloud "$image" "Desktop" vmpane \
        "$APP/Contents/Helpers/qemu/bin/qemu-img" "$HOME/VMPaneItest/cloud" --desktop) || { it_fail "the create failed"; return 1; }
    jq -e '.install.desktop == true' "$bundle/config.json" >/dev/null || { it_fail "not a Desktop install"; return 1; }
    pid=$(it_start_helper "$bundle") || return 1
    socket=$(it_socket "$bundle")
    started=$SECONDS
    it_rpc "$socket" vm.start '{"headless": true}' >/dev/null || it_fail "vm.start failed" || return 1
    it_wait_for 2700 bash -c "/usr/bin/python3 '$VMPANE_ROOT/itest/lib/rpc.py' '$socket' agent.status 2>/dev/null | jq -e '.connected and .session' >/dev/null" \
        || { it_screenshot "$socket" "$VMPANE_ROOT/itest/results/linux-cloud-desktop-failure.png" 1600; it_fail "no signed-in desktop"; return 1; }
    echo "linux-cloud-desktop: GNOME signed in $((SECONDS - started)) s after start"
    sleep 20  # first-login extras settle
    it_screenshot "$socket" "$VMPANE_ROOT/itest/results/linux-cloud-desktop-gnome.png" 8192

    it_dsi_allow exec "$password" || it_fail "cannot let agents sign in" || return 1
    # Ubuntu's first-login welcome fills the screen, and GNOME opens a window started from outside the desktop (no
    # activation token) behind the focused one.
    /usr/bin/python3 "$VMPANE_ROOT/itest/lib/agent_exec.py" "$socket" 'pkill -f "[g]nome-initial-setup"; true' >/dev/null || true
    sleep 3
    # An app of the desktop's own, started by the command itself (not handed to a running instance).
    local app title
    app=$(/usr/bin/python3 "$VMPANE_ROOT/itest/lib/agent_exec.py" "$socket" \
        'for a in gnome-calculator gnome-text-editor gnome-characters loupe; do command -v $a >/dev/null && { echo $a; break; }; done' | tr -d '\r')
    case $app in
        gnome-calculator) title=mod ;;  # its keypad (the header shows the mode, not a title) gnome-text-editor) title=Document ;; gnome-characters) title=Characters ;;
        loupe) title=Image ;; *) /usr/bin/python3 "$VMPANE_ROOT/itest/lib/agent_exec.py" "$socket" 'ls /usr/share/applications' >&2
            it_fail "no known app on the desktop"; return 1 ;;
    esac
    echo "linux-cloud-desktop: opening $app"
    if ! it_dsi launch "$cli" "$app" "$title"; then
        /usr/bin/python3 "$VMPANE_ROOT/itest/lib/agent_exec.py" "$socket" --user \
            "pgrep -fa $app; systemctl --user show-environment | grep -E 'DISPLAY|XDG_RUNTIME|DBUS'" >&2
        it_screenshot "$socket" "$VMPANE_ROOT/itest/results/linux-cloud-desktop-launch-failure.png" 1600
        it_fail "the desktop launch failed"
        return 1
    fi
    # By process name (at most 15 characters), quote-free: the check runs inside another shell's quotes.
    it_dsi_kill_closes "pgrep -x ${app:0:15}" || return 1
    it_dsi_allow control "$password" || return 1
    it_dsi sign-in "$cli" already_signed_in || { it_fail "sign-in while signed in"; return 1; }
    # Logged out: GDM's login screen (logind's greeter session).
    /usr/bin/python3 "$VMPANE_ROOT/itest/lib/agent_exec.py" "$socket" 'loginctl terminate-user vmpane' >/dev/null
    it_wait_for 60 bash -c "! /usr/bin/python3 '$VMPANE_ROOT/itest/lib/rpc.py' '$socket' agent.status | jq -e .session >/dev/null" \
        || it_fail "the session did not end" || return 1
    sleep 10
    it_dsi sign-in "$cli" signed_in \
        || { it_screenshot "$socket" "$VMPANE_ROOT/itest/results/linux-cloud-desktop-greeter-failure.png" 1600; it_fail "GDM sign-in failed"; return 1; }
    it_dsi_no_leak "$password"
}
