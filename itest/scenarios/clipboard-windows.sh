# The clipboard of a Windows 11 ARM guest through its VMPane agent (vm.clipboard.read/write; the agent's session
# helper owns the signed-in user's clipboard): text both ways with Windows line ends in the guest, PNG into the
# guest (also as a bitmap, which most Windows apps paste), a bitmap copied in the guest read as PNG, a file
# copied in the guest named by its guest path and fetched, and formatted text both ways (CF_HTML with right
# offsets, RTF a rich text box reads). The window's sharing (with a named pasteboard of the test's, never the
# Mac's: VMPANE_TEST_PASTEBOARD): a folder and a file copied in the guest land in the staging folder, and files
# and a folder copied on the Mac reach the guest's clipboard as files (Explorer's CF_HDROP, copy). A file dragged
# in the guest is caught by the agent's drag probe and the drag ends cancelled, the file left where it was.
# The golden install signs nobody in: the scenario turns on automatic sign-in with a fresh password and restarts
# Windows. VMPANE_ITEST_WINDOWS_AGENT=<vmpane-agent.exe>
# first puts that agent in place of the golden's (one not released yet: cargo xwin build in agent/).
# Sourced by scripts/itest.sh with $APP set. Exit 77 without a Windows ISO, the MSI, or 15 GiB free.

source "$VMPANE_ROOT/itest/lib/common.sh"
IT_SCENARIO=clipboard-windows

it_agent_exec() { /usr/bin/python3 "$VMPANE_ROOT/itest/lib/agent_exec.py" "$socket" "$@"; }
it_agent_connected() { [[ $(it_rpc "$socket" agent.status | jq -r .connected) == true ]]; }
it_agent_session() { it_rpc "$socket" agent.status 2>/dev/null | jq -e '.connected and .session' >/dev/null; }
# Runs clip.ps1 <op> as the signed-in user; its output has no CR.
it_clip() { it_agent_exec --user --timeout-ms 60000 "powershell -NoProfile -ExecutionPolicy Bypass -File C:\\Users\\Public\\clip.ps1 $1" | tr -d '\r'; }
it_push() { it_rpc "$socket" agent.file.push "$(jq -n --arg h "$1" --arg g "$2" '{hostPath: $h, guestPath: $g}')" >/dev/null; }

scenario_run() {
    local golden work bundle pid socket status=0 out got png sum board staging center
    compgen -G "$IT_WINDOWS_EXTRA/*.msi" >/dev/null || { echo "clipboard-windows: no agent MSI (guest-tools/fetch-agent-msi.sh)" >&2; return 77; }
    (($(df -g "$HOME" | awk 'NR == 2 {print $4}') >= 15)) || { echo "clipboard-windows: needs 15 GiB free" >&2; return 77; }
    golden=$(it_golden_windows) || status=$?
    ((status == 0)) || return "$status"
    work=$(mktemp -d /tmp/vp-cw.XXXXXX)
    export VMPANE_SUPPORT_DIR="$work/s" VMPANE_TEST_PASTEBOARD="app.vmpane.itest.$$"
    board=$VMPANE_TEST_PASTEBOARD
    staging="$VMPANE_SUPPORT_DIR/Caches/app.vmpane.mac.vm/Clipboard"
    mkdir -p "$VMPANE_SUPPORT_DIR/VMs"
    bundle="$VMPANE_SUPPORT_DIR/VMs/W.vmpane"
    it_clone_bundle "$golden" "$bundle"
    rm -f "$bundle/.agent"
    jq '.clipboard.mode = "both"' "$bundle/config.json" >"$bundle/config.new" && mv "$bundle/config.new" "$bundle/config.json"
    chmod 600 "$bundle/config.json"
    trap 'set +e; [[ -n ${pid:-} ]] && kill -TERM "$pid" 2>/dev/null && it_wait_exit "$pid" 150; it_pasteboard "$board" release; rm -rf "$work"; true' RETURN

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
    # The fragment by CF_HTML's byte offsets and by its markers, whether a rich text box reads the RTF as bold. The
    # raw bytes, read as UTF-8 as Word and browsers do (.NET Framework's GetData decodes them as the ANSI code page).
    'get-rich' {
        Add-Type -Namespace V -Name Raw -MemberDefinition @'
[DllImport("user32.dll")] static extern bool OpenClipboard(IntPtr owner);
[DllImport("user32.dll")] static extern bool CloseClipboard();
[DllImport("user32.dll")] static extern IntPtr GetClipboardData(uint format);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern uint RegisterClipboardFormat(string name);
[DllImport("kernel32.dll")] static extern IntPtr GlobalLock(IntPtr memory);
[DllImport("kernel32.dll")] static extern bool GlobalUnlock(IntPtr memory);
[DllImport("kernel32.dll")] static extern UIntPtr GlobalSize(IntPtr memory);
public static byte[] Get(string name) {
    if (!OpenClipboard(IntPtr.Zero)) return null;
    try {
        IntPtr memory = GetClipboardData(RegisterClipboardFormat(name));
        if (memory == IntPtr.Zero) return null;
        byte[] bytes = new byte[(int)GlobalSize(memory)];
        Marshal.Copy(GlobalLock(memory), bytes, 0, bytes.Length);
        GlobalUnlock(memory);
        return bytes;
    } finally { CloseClipboard(); }
}
'@
        $bytes = [V.Raw]::Get('HTML Format')
        $nul = [Array]::IndexOf($bytes, [byte]0)
        if ($nul -gt 0) { $bytes = $bytes[0..($nul - 1)] }
        $html = [Text.Encoding]::UTF8.GetString($bytes)
        $start = [int][regex]::Match($html, 'StartFragment:(\d+)').Groups[1].Value
        $end = [int][regex]::Match($html, 'EndFragment:(\d+)').Groups[1].Value
        $byOffsets = [Text.Encoding]::UTF8.GetString($bytes, $start, $end - $start)
        $from = $html.IndexOf('<!--StartFragment-->') + 20
        $marked = $html.Substring($from, $html.IndexOf('<!--EndFragment-->') - $from)
        $box = New-Object Windows.Forms.RichTextBox
        $box.Rtf = $clip::GetText([Windows.Forms.TextDataFormat]::Rtf)
        $box.Select(0, 4)
        "offsets=$byOffsets marked=$marked bold=$($box.SelectionFont.Bold) text=$($clip::GetText())"
    }
    # Formatted text as Word and browsers copy it: CF_HTML (byte offsets in its header), RTF and plain text.
    'set-rich' {
        $pre = '<html><body><!--StartFragment-->'; $frag = '<i>guest</i> rich'; $post = '<!--EndFragment--></body></html>'
        $header = "Version:0.9`r`nStartHTML:{0:D10}`r`nEndHTML:{1:D10}`r`nStartFragment:{2:D10}`r`nEndFragment:{3:D10}`r`n"
        $n = ($header -f 0, 0, 0, 0).Length
        $cf = ($header -f $n, ($n + $pre.Length + $frag.Length + $post.Length), ($n + $pre.Length), ($n + $pre.Length + $frag.Length)) + $pre + $frag + $post
        $data = New-Object Windows.Forms.DataObject
        $data.SetData([Windows.Forms.DataFormats]::Html, $cf)
        $data.SetData([Windows.Forms.DataFormats]::Rtf, '{\rtf1\ansi {\i guest} rich}')
        $data.SetData([Windows.Forms.DataFormats]::UnicodeText, 'guest rich')
        $clip::SetDataObject($data, $true)
    }
    'set-folder' {
        $folder = 'C:\Users\Public\clip-folder'
        New-Item -ItemType Directory -Force -Path "$folder\sub" | Out-Null
        [IO.File]::WriteAllText("$folder\sub\deep.txt", 'deep in the guest')
        [IO.File]::WriteAllText("$folder\top.txt", 'top')
        [IO.File]::WriteAllText('C:\Users\Public\clip-loose.txt', 'loose')
        $files = New-Object Collections.Specialized.StringCollection
        [void]$files.Add($folder); [void]$files.Add('C:\Users\Public\clip-loose.txt')
        $clip::SetFileDropList($files)
    }
    # The files on the clipboard: each one's path and first line (a folder: its entries), then the paste's effect.
    'get-files' {
        foreach ($f in $clip::GetFileDropList()) {
            if (Test-Path -LiteralPath $f -PathType Container) {
                "$f|" + ((Get-ChildItem -LiteralPath $f -Recurse -Name | Sort-Object) -join ',')
            } else { "$f|" + (Get-Content -LiteralPath $f -TotalCount 1) }
        }
        $effect = $clip::GetData('Preferred DropEffect')
        "effect=" + $(if ($effect) { $effect.ReadByte() } else { 'none' })
    }
}
EOF
    # A file to drag, and a window to drag it from (the whole screen, in front); the drag's outcome is written down.
    cat >"$work/drag-source.ps1" <<'EOF'
Add-Type -AssemblyName System.Windows.Forms
[IO.File]::WriteAllText('C:\Users\Public\drag-me.txt', 'drag me')
$form = New-Object Windows.Forms.Form
$form.TopMost = $true
$form.WindowState = 'Maximized'
$form.Add_Shown({ [IO.File]::WriteAllText('C:\Users\Public\drag-ready.txt', 'ready') })
$form.Add_MouseDown({
    $files = New-Object Collections.Specialized.StringCollection
    [void]$files.Add('C:\Users\Public\drag-me.txt')
    $data = New-Object Windows.Forms.DataObject
    $data.SetFileDropList($files)
    $effect = $form.DoDragDrop($data, [Windows.Forms.DragDropEffects]'Copy, Move')
    [IO.File]::WriteAllText('C:\Users\Public\drag-result.txt', "$effect")
    $form.Close()
})
[Windows.Forms.Application]::Run($form)
EOF
    it_push "$work/clip.ps1" 'C:\Users\Public\clip.ps1' || it_fail "push failed" || return 1
    it_push "$work/drag-source.ps1" 'C:\Users\Public\drag-source.ps1' || it_fail "push failed" || return 1

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

    # Formatted text, into the guest: CF_HTML whose offsets and markers both give the fragment (UTF-8), RTF bold.
    it_rpc "$socket" agent.status | jq -e '.caps | index("clipboard.rich")' >/dev/null ||
        it_fail "the guest agent has no formatted text (clipboard.rich)" || return 1
    it_rpc "$socket" vm.clipboard.write "$(jq -n '{items: [{type: "text", text: "bold text"},
        {type: "html", text: "<html><head><style>b {color: red}</style></head><body><b>bold</b> text ✓</body></html>"},
        {type: "rtf", text: "{\\rtf1\\ansi {\\b bold} text}"}]}')" >/dev/null || it_fail "vm.clipboard.write html failed" || return 1
    got=$(it_clip get-rich)
    [[ $got == 'offsets=<b>bold</b> text ✓ marked=<b>bold</b> text ✓ bold=True text=bold text' ]] ||
        it_fail "host → guest formatted text arrived as '$got'" || return 1
    # Out of the guest, through the method and through the window's sharing.
    it_clip set-rich >/dev/null || it_fail "the guest could not copy formatted text" || return 1
    got=$(it_rpc "$socket" vm.clipboard.read '{"types": ["text", "html", "rtf"]}' | jq -r '[.items[] | .type + "=" + .text] | join(" ")')
    [[ $got == *'text=guest rich'* && $got == *'<i>guest</i> rich'* && $got == *'rtf={\rtf1\ansi {\i guest} rich}'* ]] ||
        it_fail "guest → host formatted text arrived as '$got'" || return 1
    it_wait_for 15 bash -c "'$(it_swift_tool pasteboard)' '$board' get | jq -e '.html // \"\" | contains(\"<i>guest</i> rich\")' >/dev/null" ||
        it_fail "the window's sharing did not bring the formatted text: $(it_pasteboard "$board" get)" || return 1
    echo "clipboard-windows: formatted text both ways (CF_HTML offsets and markers, RTF bold; the window's sharing too)"

    # A folder and a file copied in the guest: in the staging folder, walked, quarantined, named on the pasteboard.
    it_clip set-folder >/dev/null || it_fail "the guest could not copy a folder" || return 1
    it_wait_for 30 bash -c "'$(it_swift_tool pasteboard)' '$board' get | jq -e '.files | length == 2' >/dev/null" ||
        it_fail "the guest's folder did not reach the pasteboard: $(it_pasteboard "$board" get)" || return 1
    got=$(it_pasteboard "$board" get | jq -r '.files[]')
    local folder=${got%%$'\n'*}
    [[ $folder == "$staging"/*/*/clip-folder && $(cat "$folder/sub/deep.txt") == 'deep in the guest' && -f $folder/top.txt ]] ||
        it_fail "the guest's folder landed as '$got'" || return 1
    [[ $(sed -n 2p <<<"$got") == "$staging"/*/*/clip-loose.txt ]] || it_fail "the loose file landed as '$got'" || return 1
    xattr -p com.apple.quarantine "$folder/sub/deep.txt" >/dev/null 2>&1 || it_fail "the guest's file is not quarantined" || return 1
    echo "clipboard-windows: a folder and a file copied in the guest wait in the staging folder, quarantined"

    # Files and a folder copied on the Mac: put in the guest, on its clipboard as files that Explorer copies.
    mkdir -p "$work/mac/Album"
    printf 'from the Mac' >"$work/mac/report ✓.txt"
    printf 'photo' >"$work/mac/Album/photo.txt"
    it_pasteboard "$board" set-files "$work/mac/report ✓.txt" "$work/mac/Album" || it_fail "cannot fill the test pasteboard" || return 1
    it_wait_for 30 bash -c "powershell_out=\$(/usr/bin/python3 '$VMPANE_ROOT/itest/lib/agent_exec.py' '$socket' --user 'powershell -NoProfile -ExecutionPolicy Bypass -File C:\\Users\\Public\\clip.ps1 get-files'); [[ \$powershell_out == *Album* ]]" ||
        it_fail "the Mac's files did not reach the guest's clipboard: $(it_clip get-files)" || return 1
    got=$(it_clip get-files)
    [[ $got == *'\AppData\Local\Temp\VMPane Clipboard\'*'\report ✓.txt|from the Mac'* && $got == *'\Album|photo.txt'* && $got == *'effect=1'* ]] ||
        it_fail "the Mac's files reached the guest as '$got'" || return 1
    echo "clipboard-windows: files and a folder copied on the Mac are files on the guest's clipboard (staged, copy)"

    # Dragging out: a file dragged in the guest is caught by the probe, and the drag ends cancelled (not moved).
    # The agent's own folder is closed to the user: the probe runs from a copy.
    it_agent_exec 'copy /y "C:\Program Files\VMPane\Agent\vmpane-agent.exe" C:\Users\Public\probe-agent.exe' >/dev/null ||
        it_fail "cannot copy the agent for the probe" || return 1
    it_rpc "$socket" agent.exec '{"argv": ["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "C:\\Users\\Public\\drag-source.ps1"], "as": "user", "desktop": true}' >/dev/null ||
        it_fail "cannot open the drag source" || return 1
    it_wait_for 30 bash -c "/usr/bin/python3 '$VMPANE_ROOT/itest/lib/agent_exec.py' '$socket' 'if exist C:\\Users\\Public\\drag-ready.txt (exit 0) else (exit 1)' >/dev/null" ||
        it_fail "the drag source did not open" || return 1
    center=$(it_rpc "$socket" vm.input.batch '{"actions": [{"type": "wait", "ms": 1}]}' | jq -c '{x: (.screen.width / 2 | floor), y: (.screen.height / 2 | floor)}')
    it_rpc "$socket" vm.input.pointer "$(jq -n --argjson c "$center" '$c + {buttons: 1}')" >/dev/null
    for step in 8 16 24; do
        it_rpc "$socket" vm.input.pointer "$(jq -n --argjson c "$center" --argjson d "$step" '{x: ($c.x + $d), y: ($c.y + $d), buttons: 1}')" >/dev/null
        sleep 0.2
    done
    it_agent_exec --user 'C:\Users\Public\probe-agent.exe drag-probe' >"$work/probe.json" &
    local probe=$!
    sleep 2
    it_rpc "$socket" vm.input.pointer "$(jq -n --argjson c "$center" '$c + {buttons: 0}')" >/dev/null
    wait "$probe" || it_fail "the drag probe failed" || return 1
    got=$(jq -r '[.items[] | .path + ":" + (.folder | tostring)] | join(" ")' "$work/probe.json")
    [[ $got == 'C:\Users\Public\drag-me.txt:false' ]] || it_fail "the probe saw '$(cat "$work/probe.json")'" || return 1
    it_wait_for 15 bash -c "/usr/bin/python3 '$VMPANE_ROOT/itest/lib/agent_exec.py' '$socket' 'type C:\\Users\\Public\\drag-result.txt' 2>/dev/null | grep -q None" ||
        it_fail "the guest's drag did not end cancelled: $(it_agent_exec 'type C:\Users\Public\drag-result.txt' 2>&1)" || return 1
    it_agent_exec 'if exist C:\Users\Public\drag-me.txt (exit 0) else (exit 1)' >/dev/null || it_fail "the dragged file was moved" || return 1
    echo "clipboard-windows: a file dragged in the guest is caught by the probe; the drag ends cancelled, the file stays"

    it_rpc "$socket" vm.stop '{"mode": "force"}' >/dev/null
    it_rpc "$socket" helper.shutdown >/dev/null
    it_wait_exit "$pid" 30 || true
    pid=
    return 0
}
