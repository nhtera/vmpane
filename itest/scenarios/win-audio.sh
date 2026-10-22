# Windows sound with the microphone on (issue #7), in a real guest: QEMU gets the `spice` audiodev with a speaker and a
# microphone (hda-micro); Windows lists both, a speaker and a microphone; a sound the guest plays reaches the helper
# over SPICE; and the guest's recording reaches the helper too, start and end (the Mac's microphone is open only while
# the guest records). The Mac's microphone is never opened here
# (VMPANE_TEST_NO_MICROPHONE: its permission question would be a dialog on the Mac's screen): a person checks
# that a mic test in the guest hears it (docs/release-checklist.md). Skips without the golden or 15 GiB free.
# Sourced by scripts/itest.sh with $APP set.

source "$VMPANE_ROOT/itest/lib/common.sh"
IT_SCENARIO=win-audio

it_agent_exec() { /usr/bin/python3 "$VMPANE_ROOT/itest/lib/agent_exec.py" "$socket" "$@"; }
# Runs PowerShell script $1 in the guest (as -EncodedCommand: no quoting through the shells in between).
# (Progress records off: PowerShell writes them to stderr as CLIXML, without a final newline.)
wa_ps() {
    it_agent_exec --timeout-ms 30000 \
        "powershell -NoProfile -EncodedCommand $(printf '%s' "\$ProgressPreference = 'SilentlyContinue'; $1" | iconv -f UTF-8 -t UTF-16LE | base64)"
}
wa_endpoints() { wa_ps 'Get-PnpDevice -Class AudioEndpoint -PresentOnly | Where-Object Status -eq OK | Select-Object -ExpandProperty FriendlyName' | tr -d '\r'; }
# The helper's SPICE audio lines since $1.
wa_log() { /usr/bin/log show --info --start "$1" --predicate 'category == "spice-audio"' --style compact 2>/dev/null; }

scenario_run() {
    local golden work bundle pid socket status since endpoints args
    (($(df -g "$HOME" | awk 'NR == 2 {print $4}') >= 15)) || { echo "win-audio: needs 15 GiB free" >&2; return 77; }
    golden=$(it_golden_windows) || { status=$?; return "$status"; }
    work=$(mktemp -d /tmp/vp-wa.XXXXXX)
    export VMPANE_SUPPORT_DIR="$work/s" VMPANE_TEST_NO_MICROPHONE=1
    mkdir -p "$VMPANE_SUPPORT_DIR/VMs"
    bundle="$VMPANE_SUPPORT_DIR/VMs/W.vmpane"
    it_clone_bundle "$golden" "$bundle"
    trap 'set +e; [[ -n ${pid:-} ]] && kill -TERM "$pid" 2>/dev/null && it_wait_exit "$pid" 150; rm -rf "$work"; trap - RETURN; true' RETURN
    pid=$(it_start_helper "$bundle") || return 1
    socket=$(it_socket "$bundle")
    it_rpc "$socket" vm.settings.apply '{"patch": {"audio": {"output": true, "input": true}}}' >/dev/null \
        || it_fail "cannot turn sound and the microphone on" || return 1
    since=$(date '+%Y-%m-%d %H:%M:%S')
    it_rpc "$socket" vm.start '{"headless": true}' >/dev/null || it_fail "vm.start failed" || return 1
    it_wait_for 180 bash -c "/usr/bin/python3 '$VMPANE_ROOT/itest/lib/rpc.py' '$socket' agent.status | jq -e .connected >/dev/null" \
        || it_fail "the guest tools did not connect" || return 1

    args=$(ps -axo command= | grep "[q]emu-system-aarch64.*$bundle" | tr ' ' '\n')
    grep -qx 'spice,id=snd0' <<<"$args" && grep -qx 'hda-micro,bus=hda.0,audiodev=snd0' <<<"$args" && ! grep -q coreaudio <<<"$args" \
        || it_fail "QEMU's sound devices: $(grep -E 'audiodev|hda' <<<"$args" | tr '\n' ' ')" || return 1
    echo "win-audio: QEMU sends sound over SPICE, with a speaker and a microphone (hda-micro)"

    for _ in 1 2 3 4 5 6; do
        endpoints=$(wa_endpoints)
        grep -qi microphone <<<"$endpoints" && break
        sleep 10
    done
    grep -qi 'speaker' <<<"$endpoints" && grep -qi 'microphone' <<<"$endpoints" \
        || it_fail "Windows lists no speaker and microphone: $(tr '\n' ';' <<<"$endpoints")" || return 1
    echo "win-audio: Windows lists $(tr '\n' ';' <<<"$endpoints" | sed 's/;$//')"

    # A sound in the guest: SPICE playback starts in the helper.
    wa_ps '(New-Object Media.SoundPlayer "C:\Windows\Media\chimes.wav").PlaySync()' >/dev/null
    it_wait_for 15 bash -c "/usr/bin/log show --info --start '$since' --predicate 'category == \"spice-audio\"' --style compact 2>/dev/null | grep -q 'guest sound playing'" \
        || { wa_log "$since" | tail -5 >&2; it_fail "the guest's sound did not reach the helper"; return 1; }
    echo "win-audio: the guest's sound plays through the helper ($(wa_log "$since" | grep -o 'guest sound playing.*' | head -1))"

    # A recording in the guest (Windows' own sound recorder API): the helper is asked for the microphone.
    wa_ps 'Add-Type -Name W -Namespace M -MemberDefinition '"'"'[DllImport("winmm.dll")] public static extern int mciSendString(string c, System.Text.StringBuilder r, int l, System.IntPtr h);'"'"'
[M.W]::mciSendString("open new type waveaudio alias r", $null, 0, 0) | Out-Null
[M.W]::mciSendString("record r", $null, 0, 0) | Out-Null
Start-Sleep 2
[M.W]::mciSendString("close r", $null, 0, 0) | Out-Null' >/dev/null
    it_wait_for 15 bash -c "/usr/bin/log show --info --start '$since' --predicate 'category == \"spice-audio\"' --style compact 2>/dev/null | grep -q 'the guest records'" \
        || { wa_log "$since" | tail -5 >&2; it_fail "the guest's recording did not reach the helper"; return 1; }
    it_wait_for 15 bash -c "/usr/bin/log show --info --start '$since' --predicate 'category == \"spice-audio\"' --style compact 2>/dev/null | grep -q 'the guest stopped recording'" \
        || { wa_log "$since" | tail -5 >&2; it_fail "the helper did not see the guest stop recording (the Mac's microphone would stay open)"; return 1; }
    echo "win-audio: the guest's recording reaches the helper ($(wa_log "$since" | grep -o 'the guest records.*' | head -1)), and its end too"
}
