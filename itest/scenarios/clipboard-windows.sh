# The clipboard of a Windows 11 ARM guest through its VMPane agent (vm.clipboard.read/write; the agent's session
# helper owns the signed-in user's clipboard): text both ways with Windows line ends in the guest, PNG into the
# guest (also as a bitmap, which most Windows apps paste), a bitmap copied in the guest read as PNG, and a file
# copied in the guest named by its guest path and fetched. The golden install signs nobody in: the scenario turns
# on automatic sign-in with a fresh password and restarts Windows. VMPANE_ITEST_WINDOWS_AGENT=<vmpane-agent.exe>
# first puts that agent in place of the golden's (one not released yet: cargo xwin build in agent/).
# Sourced by scripts/itest.sh with $APP set. Exit 77 without a Windows ISO, the MSI, or 15 GiB free.

source "$VMPANE_ROOT/itest/lib/common.sh"
IT_SCENARIO=clipboard-windows

it_agent_exec() { /usr/bin/python3 "$VMPANE_ROOT/itest/lib/agent_exec.py" "$socket" "$@"; }
it_agent_connected() { [[ $(it_rpc "$socket" agent.status | jq -r .connected) == true ]]; }
it_agent_session() { it_rpc "$socket" agent.status 2>/dev/null | jq -e '.connected and .session' >/dev/null; }
# Runs clip.ps1 <op> as the signed-in user; its output has no CR.
it_clip() { it_agent_exec --user "powershell -NoProfile -ExecutionPolicy Bypass -File C:\\Users\\Public\\clip.ps1 $1" | tr -d '\r'; }
it_push() { it_rpc "$socket" agent.file.push "$(jq -n --arg h "$1" --arg g "$2" '{hostPath: $h, guestPath: $g}')" >/dev/null; }

scenario_run() {
    local golden work bundle pid socket status=0 out got png sum
    compgen -G "$IT_WINDOWS_EXTRA/*.msi" >/dev/null || { echo "clipboard-windows: no agent MSI (guest-tools/fetch-agent-msi.sh)" >&2; return 77; }
    (($(df -g "$HOME" | awk 'NR == 2 {print $4}') >= 15)) || { echo "clipboard-windows: needs 15 GiB free" >&2; return 77; }
    golden=$(it_golden_windows) || status=$?
    ((status == 0)) || return "$status"
    work=$(mktemp -d /tmp/vp-cw.XXXXXX)
    export VMPANE_SUPPORT_DIR="$work/s"
    mkdir -p "$VMPANE_SUPPORT_DIR/VMs"
    bundle="$VMPANE_SUPPORT_DIR/VMs/W.vmpane"
    it_clone_bundle "$golden" "$bundle"
    rm -f "$bundle/.agent"
    jq '.clipboard.mode = "both"' "$bundle/config.json" >"$bundle/config.new" && mv "$bundle/config.new" "$bundle/config.json"
    chmod 600 "$bundle/config.json"
    trap 'set +e; [[ -n ${pid:-} ]] && kill -TERM "$pid" 2>/dev/null && it_wait_exit "$pid" 150; rm -rf "$work"; true' RETURN

    pid=$(it_start_helper "$bundle") || return 1
    socket=$(it_socket "$bundle")
    out=$(it_rpc "$socket" vm.start '{"headless": true}') || it_fail "vm.start failed: $out" || return 1
    it_wait_for 180 it_agent_connected || it_fail "the agent did not connect within 180 s" || return 1

    # Sign the install's user in automatically (a fresh password), swap in the agent under test, restart.
    cat >"$work/signin.ps1" <<'EOF'
$ErrorActionPreference = 'Stop'
$user = Get-LocalUser | Where-Object { $_.Enabled -and $_.Name -notin 'Administrator', 'DefaultAccount', 'Guest', 'WDAGUtilityAccount' } | Select-Object -First 1
$password = 'Vp-' + [guid]::NewGuid().ToString('N')
$user | Set-LocalUser -Password (ConvertTo-SecureString $password -AsPlainText -Force)
$key = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
Set-ItemProperty $key AutoAdminLogon '1'
Set-ItemProperty $key DefaultUserName $user.Name
Set-ItemProperty $key DefaultPassword $password
$new = 'C:\Windows\Temp\vmpane-agent.new.exe'
if (Test-Path $new) {
    # A running program can be renamed, not overwritten; the service starts the new one after the restart.
    $exe = 'C:\Program Files\VMPane\Agent\vmpane-agent.exe'
    Move-Item $exe 'C:\Windows\Temp\vmpane-agent.old.exe' -Force
    Move-Item $new $exe
}
shutdown.exe /r /t 3
EOF
    if [[ -n ${VMPANE_ITEST_WINDOWS_AGENT:-} ]]; then
        it_push "$VMPANE_ITEST_WINDOWS_AGENT" 'C:\Windows\Temp\vmpane-agent.new.exe' || it_fail "pushing the agent failed" || return 1
        echo "clipboard-windows: testing the agent $VMPANE_ITEST_WINDOWS_AGENT"
    fi
    it_push "$work/signin.ps1" 'C:\Windows\Temp\signin.ps1' || it_fail "push failed" || return 1
    it_agent_exec 'powershell -NoProfile -ExecutionPolicy Bypass -File C:\Windows\Temp\signin.ps1' >/dev/null ||
        it_fail "turning on automatic sign-in failed" || return 1
    it_wait_for 60 bash -c "! /usr/bin/python3 '$VMPANE_ROOT/itest/lib/rpc.py' '$socket' agent.status | jq -e .connected >/dev/null" ||
        it_fail "Windows did not restart" || return 1
    it_wait_for 240 it_agent_session || it_fail "no signed-in session helper within 240 s of the restart" || return 1
    it_rpc "$socket" agent.status | jq -c '{version, caps}'
    it_rpc "$socket" agent.status | jq -e '.caps | index("clipboard")' >/dev/null ||
        it_fail "the guest agent has no clipboard (set VMPANE_ITEST_WINDOWS_AGENT, or a newer agent MSI)" || return 1

    # The user's side: .NET's clipboard, which reads and writes bitmaps the way Windows apps do. In Public: a
    # standard user cannot read what the agent puts in C:\Windows\Temp.
    cat >"$work/clip.ps1" <<'EOF'
param([string]$Op)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
$clip = [Windows.Forms.Clipboard]
switch ($Op) {
    # Line ends spelled out, so they survive the trip.
    'get-text' { $clip::GetText().Replace("`r", '\r').Replace("`n", '\n') }
    'set-text' { $clip::SetText('guest ' + [char]0x2713 + "`r`nline two") }
    'get-image' {
        $image = $clip::GetImage()
        $png = $clip::GetData('PNG')
        $sum = if ($png) { -join ([Security.Cryptography.SHA256]::Create().ComputeHash($png) | ForEach-Object { $_.ToString('x2') }) } else { 'none' }
        "$($image.Width)x$($image.Height) $($image.GetPixel(0, 0).R) png=$sum"
    }
    'set-bitmap' {
        $bitmap = New-Object Drawing.Bitmap 37, 23
        $graphics = [Drawing.Graphics]::FromImage($bitmap)
        $graphics.Clear([Drawing.Color]::FromArgb(255, 200, 30, 60))
        $graphics.Dispose()
        $clip::SetImage($bitmap)
    }
    'set-file' {
        $file = 'C:\Users\Public\clip-file.txt'
        [IO.File]::WriteAllText($file, 'file from the guest')
        $files = New-Object Collections.Specialized.StringCollection
        [void]$files.Add($file)
        $clip::SetFileDropList($files)
    }
}
EOF
    it_push "$work/clip.ps1" 'C:\Users\Public\clip.ps1' || it_fail "push failed" || return 1

    # Text: CRLF in the guest, LF on the Mac.
    it_rpc "$socket" vm.clipboard.write "$(jq -n '{items: [{type: "text", text: "host ✓ — one\ntwo"}]}')" >/dev/null ||
        it_fail "vm.clipboard.write text failed" || return 1
    got=$(it_clip get-text)
    [[ $got == 'host ✓ — one\r\ntwo' ]] || it_fail "host → guest text arrived as '$got'" || return 1
    it_clip set-text >/dev/null || it_fail "the guest could not copy text" || return 1
    got=$(it_rpc "$socket" vm.clipboard.read '{"types": ["text"]}' | jq -r '.items[] | select(.type == "text") | .text')
    [[ $got == $'guest ✓\nline two' ]] || it_fail "guest → host text arrived as '$got'" || return 1
    echo "clipboard-windows: text host → guest and guest → host (UTF-16, line ends converted) OK"

    # PNG into the guest: kept byte for byte, and pasteable as a bitmap.
    png="$work/image.png"
    it_screenshot "$socket" "$png" 320 || it_fail "no screenshot to use as an image" || return 1
    sum=$(shasum -a 256 "$png" | cut -d' ' -f1)
    it_rpc "$socket" vm.clipboard.write "$(jq -n --arg d "$(base64 <"$png")" '{items: [{type: "png", dataB64: $d}]}')" >/dev/null ||
        it_fail "vm.clipboard.write png failed" || return 1
    got=$(it_clip get-image) || it_fail "the guest clipboard holds no image" || return 1
    [[ $got == "$(sips -g pixelWidth -g pixelHeight "$png" | awk '/pixelWidth/ {w = $2} /pixelHeight/ {h = $2} END {print w "x" h}') "*" png=$sum" ]] ||
        it_fail "host → guest PNG: the guest sees '$got'" || return 1
    echo "clipboard-windows: PNG host → guest byte for byte, and as a bitmap"

    # A bitmap copied in the guest (no PNG on the clipboard) reaches the Mac as PNG.
    it_clip set-bitmap >/dev/null || it_fail "the guest could not copy a bitmap" || return 1
    it_rpc "$socket" vm.clipboard.read '{"types": ["png"]}' | jq -r '.items[] | select(.type == "png") | .dataB64' |
        base64 -d >"$work/back.png"
    got=$(sips -g pixelWidth -g pixelHeight "$work/back.png" 2>/dev/null | awk '/pixelWidth/ {w = $2} /pixelHeight/ {h = $2} END {print w "x" h}')
    [[ $got == 37x23 ]] || it_fail "the guest's bitmap arrived as '$got'" || return 1
    echo "clipboard-windows: a bitmap copied in the guest arrives as a 37x23 PNG"

    # Files: named by their guest paths, fetched with agent.file.pull.
    it_clip set-file >/dev/null || it_fail "the guest could not copy a file" || return 1
    got=$(it_rpc "$socket" vm.clipboard.read '{"types": ["files"]}' | jq -r '.items[] | select(.type == "files") | .files[0]')
    [[ $got == 'C:\Users\Public\clip-file.txt' ]] || it_fail "the guest's copied file reads as '$got'" || return 1
    it_rpc "$socket" agent.file.pull "$(jq -n --arg g "$got" --arg h "$work/clip-file.txt" '{guestPath: $g, hostPath: $h}')" >/dev/null ||
        it_fail "cannot fetch the copied file" || return 1
    [[ $(cat "$work/clip-file.txt") == "file from the guest" ]] || it_fail "the guest's file arrived changed" || return 1
    echo "clipboard-windows: a file copied in the guest, named by its guest path and fetched"

    it_rpc "$socket" vm.stop '{"mode": "force"}' >/dev/null
    it_rpc "$socket" helper.shutdown >/dev/null
    it_wait_exit "$pid" 30 || true
    pid=
    return 0
}
