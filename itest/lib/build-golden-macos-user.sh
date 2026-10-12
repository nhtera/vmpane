#!/usr/bin/env bash
# Builds the golden macOS bundle with a user and the guest agent: a clone of the golden macOS bundle (at Setup
# Assistant) answered like a user would, through the screen (guest_ui.py: OCR + clicks and keys), with the
# account $IT_MACOS_USER, VMPane Agent.pkg installed from the tools share with sudo in Terminal, auto-login on,
# no sleep. Then it starts once more (Setup Assistant shows a few screens after the first login; they are
# answered too) and shuts down cleanly, so the guest keeps its settings. About 6 minutes.
# Usage: build-golden-macos-user.sh <bundle path>   (needs $APP, $VMPANE_ROOT)
set -euo pipefail
golden=$1
source "$VMPANE_ROOT/itest/lib/common.sh"
IT_SCENARIO=golden-macos-user

base=$(it_golden_macos)
work=$(mktemp -d /tmp/vp-golden-mu.XXXXXX)
export VMPANE_SUPPORT_DIR="$work/s"
trap 'rc=$?; set +e; [[ -n ${pid:-} ]] && kill -TERM "$pid" 2>/dev/null && it_wait_exit "$pid" 30
      if ((rc)); then tail -n 30 "$VMPANE_SUPPORT_DIR"/helper-*.log >&2; [[ -s $work/last.png ]] && cp "$work/last.png" "$golden.failed.png"; fi
      rm -rf "$work"' EXIT
rm -rf "$golden.partial" "$golden" "$golden.failed.png"
mkdir -p "$VMPANE_SUPPORT_DIR/VMs"
it_clone_bundle "$base" "$golden.partial"

ocr=$(it_ocr_binary) || { it_fail "cannot build the OCR tool"; exit 1; }
ui() { /usr/bin/python3 "$VMPANE_ROOT/itest/lib/guest_ui.py" "$socket" "$ocr" "$@"; }
boot() {
    pid=$(it_start_helper "$golden.partial") || return 1
    socket=$(it_socket "$golden.partial")
    it_rpc "$socket" vm.start '{"headless": true}' >/dev/null || { it_fail "vm.start failed"; return 1; }
}
session() {  # waits for the agent and its user session
    it_wait_for "${1:-180}" bash -c "/usr/bin/python3 '$VMPANE_ROOT/itest/lib/rpc.py' '$socket' agent.status 2>/dev/null \
        | jq -e '.connected and .session' >/dev/null"
}
shut_down() {  # a clean shutdown from inside, so the guest writes its settings
    /usr/bin/python3 "$VMPANE_ROOT/itest/lib/agent_exec.py" "$socket" 'shutdown -h now' >/dev/null || true
    it_wait_for 180 bash -c "[[ \$(/usr/bin/python3 '$VMPANE_ROOT/itest/lib/rpc.py' '$socket' vm.info | jq -r .state) == stopped ]]" \
        || { it_fail "the guest did not shut down"; return 1; }
    it_rpc "$socket" helper.shutdown >/dev/null
    it_wait_exit "$pid" 30 || true
    pid=
}

boot
sleep 20
ui setup "$IT_MACOS_USER" "$IT_MACOS_PASSWORD" || { ui shot "$work/last.png"; exit 1; }
echo "golden-macos-user: Setup Assistant done" >&2
ui install-agent "$IT_MACOS_USER" "$IT_MACOS_PASSWORD" || { ui shot "$work/last.png"; exit 1; }
session || { it_fail "the agent did not connect after the install"; exit 1; }
echo "golden-macos-user: agent installed and connected" >&2
shut_down

# The first login after setup shows a few more setup screens; answer them, then keep the guest as it is.
boot
sleep 30
ui setup "$IT_MACOS_USER" "$IT_MACOS_PASSWORD" || { ui shot "$work/last.png"; exit 1; }
session || { it_fail "the agent's session did not come back after a restart (auto-login)"; exit 1; }
shut_down

it_golden_macos_user_marker >"$golden.partial/.ready"
mv "$golden.partial" "$golden"
echo "golden-macos-user: ready ($(du -sh "$golden" | cut -f1))" >&2
