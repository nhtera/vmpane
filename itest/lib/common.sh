# Shared helpers for integration scenarios (sourced). Needs $VMPANE_ROOT and $APP.

it_helper() { echo "$APP/Contents/Helpers/VMPaneVM.app/Contents/MacOS/VMPaneVM"; }
it_rpc() { /usr/bin/python3 "$VMPANE_ROOT/itest/lib/rpc.py" "$@"; }

it_fail() {
    echo "${IT_SCENARIO:-itest}: $*" >&2
    return 1
}

it_wait_for() {  # it_wait_for <seconds> <test command…>
    local deadline=$((SECONDS + $1))
    shift
    until "$@"; do
        ((SECONDS < deadline)) || return 1
        sleep 0.2
    done
}

it_sid() { jq -r .id "$1/config.json" | tr 'A-F' 'a-f' | cut -c1-8; }

# The image's local path after downloading (once) and checking the pin in itest/images.lock.
it_image() {
    local name=$1 url sha cache="$HOME/VMPaneItest/downloads"
    read -r url sha < <(awk -v n="$name" '$1 == n {print $2, $3}' "$VMPANE_ROOT/itest/images.lock")
    [[ -n $url ]] || { it_fail "no image $name in images.lock"; return 1; }
    mkdir -p "$cache"
    local file="$cache/$(basename "$url")"
    if [[ ! -f $file ]]; then
        curl -fL --retry 3 -o "$file.partial" "$url" >&2 || return 1
        mv "$file.partial" "$file"
    fi
    [[ $(shasum -a 256 "$file" | awk '{print $1}') == "$sha" ]] || { rm -f "$file"; it_fail "sha256 mismatch for $name"; return 1; }
    echo "$file"
}

# Minimal valid bundle at $1. Optional: $2 = os (linux), $3 = extra jq filter applied to the config.
it_create_bundle() {
    local bundle=$1 os=${2:-linux} extra=${3:-.} id mac
    id=$(uuidgen)
    mac=$(printf '52:54:00:%02x:%02x:%02x' $((RANDOM % 256)) $((RANDOM % 256)) $((RANDOM % 256)))
    mkdir -p "$bundle/current/aux" "$bundle/current/state" "$bundle/snapshots" "$bundle/logs"
    chmod -R 700 "$bundle"
    jq -n --arg id "$id" --arg mac "$mac" --arg os "$os" '{
        schemaVersion: 1, id: $id, name: "itest", os: $os, backend: "vz",
        cpu: {count: 2}, memory: {mib: 2048, balloon: true},
        display: {widthPx: 1280, heightPx: 800, ppi: 144, autoResize: true, scaling: "retina"},
        disks: [{id: "root", file: "current/disk.img", format: "raw", sizeGiB: 8, bus: "virtio"}],
        removable: [], platform: {}, network: [{id: "nic0", mode: "nat", macAddress: $mac}],
        portForwards: [], shares: [], audio: {output: false, input: false},
        clipboard: {mode: "off", allowWithAgents: false}, vz: {rosetta: false, nestedVirtualization: false},
        agent: {transport: "auto"},
        mcp: {policy: "off", confirmExec: true, autoSnapshot: true, auditTypedText: false},
        ui: {closeAction: "keepRunning"}} | '"$extra" >"$bundle/config.json"
    jq -n --arg gen "$(uuidgen)" '{schemaVersion: 1, generationId: $gen}' >"$bundle/current/generation.json"
    chmod 600 "$bundle/config.json" "$bundle/current/generation.json"
}

# Starts a helper for bundle $1 (headless) in the background; echoes its pid once the socket exists.
it_start_helper() {
    local bundle=$1 sid run="$VMPANE_SUPPORT_DIR/run"
    sid=$(it_sid "$bundle")
    # Output to a log, never the caller's stdout: callers capture this function's output with $( ).
    mkdir -p "$VMPANE_SUPPORT_DIR"
    "$(it_helper)" --vm "$bundle" --headless >>"$VMPANE_SUPPORT_DIR/helper-$sid.log" 2>&1 &
    local pid=$!
    # Wait until the helper answers: a helper that died leaves its socket file behind, and a new one may first
    # reap what the old one left running (seconds).
    it_wait_for 30 bash -c "/usr/bin/python3 '$VMPANE_ROOT/itest/lib/rpc.py' '$run/$sid.sock' vm.info >/dev/null 2>&1" \
        || { it_fail "helper for $bundle did not answer on its socket"; return 1; }
    echo "$pid"
}

# Runs the UI tests named by -only-testing value $1 (xcodebuild test), output to log $2; $3, when given, is the
# result bundle path. One derived-data folder for all runs: a fresh one per run cost 800 MB and, deleted while
# Xcode's build service still wrote to it, was sometimes left behind. Variables named TEST_RUNNER_<name> reach
# the tests as <name>.
it_ui_tests() {
    xcodebuild test -project "$VMPANE_ROOT/VMPane.xcodeproj" -scheme VMPane -destination 'platform=macOS' \
        -only-testing:"$1" -derivedDataPath "$HOME/VMPaneItest/ui-derived-data" ${3:+-resultBundlePath "$3"} >"$2" 2>&1
}

# Saved VM memory can only be restored while this Mac is unlocked (Virtualization's Secure Enclave key):
# scenarios that restore skip (77) on a locked screen.
it_require_unlocked() {
    if ioreg -n Root -d1 -a | plutil -extract IOConsoleUsers xml1 -o - - 2>/dev/null \
        | grep -A1 CGSSessionScreenIsLocked | grep -q '<true/>'; then
        echo "$IT_SCENARIO: skipped: this Mac is locked (restoring saved VM memory needs it unlocked)" >&2
        return 77
    fi
}

it_socket() { echo "$VMPANE_SUPPORT_DIR/run/$(it_sid "$1").sock"; }

# The golden Linux bundle (Ubuntu cloud image, cloud-init done, prints markers on the serial console).
# Built once into ~/VMPaneItest/linux-base.vmpane; scenarios clone it.
# Bump when the golden's guest setup changes: an older golden is rebuilt.
IT_GOLDEN_LINUX_VERSION=5
it_golden_linux() {
    local golden="$HOME/VMPaneItest/linux-base.vmpane"
    if [[ $(cat "$golden/.ready" 2>/dev/null) == "$IT_GOLDEN_LINUX_VERSION" ]]; then echo "$golden"; return 0; fi
    "$VMPANE_ROOT/itest/lib/build-golden-linux.sh" "$golden" >&2 || return 1
    echo "$golden"
}

# Clones bundle $1 to $2 (APFS clone: instant, no extra space).
it_clone_bundle() { cp -cRp "$1" "$2"; rm -f "$2/.ready" "$2/logs/serial.log"; }

# Waits (up to $2 s, default 15) for process $1 to exit; it need not be a child of this shell.
it_wait_exit() { it_wait_for "${2:-15}" bash -c "! kill -0 $1 2>/dev/null"; }

# The latest "VMPANE-TICK uptime=<s> boot=<id>" of bundle $1 as "<uptime> <boot id>".
it_last_tick() { grep -a VMPANE-TICK "$1/logs/serial.log" | tail -1 | sed -E 's/.*uptime=([0-9]+) boot=([0-9a-f-]+).*/\1 \2/'; }

# Waits until bundle $1 prints a tick newer than byte offset $2 of its serial log; echoes it.
it_next_tick() {
    local bundle=$1 offset=$2 deadline=$((SECONDS + ${3:-30})) line
    while ((SECONDS < deadline)); do
        line=$(tail -c +"$((offset + 1))" "$bundle/logs/serial.log" | grep -a VMPANE-TICK | tail -1)
        if [[ -n $line ]]; then
            sed -E 's/.*uptime=([0-9]+) boot=([0-9a-f-]+).*/\1 \2/' <<<"$line"
            return 0
        fi
        sleep 0.5
    done
    return 1
}

it_log_size() { stat -f %z "$1/logs/serial.log"; }

it_state() { it_rpc "$(it_socket "$1")" vm.info | jq -r .state; }

# Clones the golden Linux bundle into a fresh throwaway support dir and starts it headless.
# Sets: work, bundle, pid, socket.
it_boot_linux_clone() {
    local golden
    golden=$(it_golden_linux) || return 1
    work=$(mktemp -d /tmp/vp-it.XXXXXX)
    export VMPANE_SUPPORT_DIR="$work/s"
    mkdir -p "$VMPANE_SUPPORT_DIR/VMs"
    bundle="$VMPANE_SUPPORT_DIR/VMs/L.vmpane"
    it_clone_bundle "$golden" "$bundle"
    pid=$(it_start_helper "$bundle") || return 1
    socket=$(it_socket "$bundle")
    it_rpc "$socket" vm.start '{"headless": true}' >/dev/null || { it_fail "vm.start failed"; return 1; }
    it_wait_for 60 grep -q VMPANE-ITEST-READY "$bundle/logs/serial.log" || { it_fail "no ready marker"; return 1; }
}

# The golden macOS bundle (installed from the pinned IPSW, at Setup Assistant).
it_golden_macos() {
    local golden="$HOME/VMPaneItest/macos-base.vmpane"
    if [[ -f "$golden/.ready" ]]; then echo "$golden"; return 0; fi
    "$VMPANE_ROOT/itest/lib/build-golden-macos.sh" "$golden" >&2 || return 1
    echo "$golden"
}

# The golden Windows bundle (VMPane's unattended install; see build-golden-windows.sh).
# Built once into ~/VMPaneItest/win11-base.vmpane; scenarios clone it. Exit 77 without a Windows ISO.
# With an agent MSI in build/guest-tools/windows-extra (guest-tools/fetch-agent-msi.sh) the install puts the agent
# in (marker .agent); a golden built without it is rebuilt once the MSI is there.
IT_GOLDEN_WINDOWS_VERSION=3
IT_WINDOWS_EXTRA="$VMPANE_ROOT/build/guest-tools/windows-extra"
it_golden_windows() {
    local golden="$HOME/VMPaneItest/win11-base.vmpane" status
    if [[ $(cat "$golden/.ready" 2>/dev/null) == "$IT_GOLDEN_WINDOWS_VERSION" ]] &&
        { [[ -f $golden/.agent ]] || ! compgen -G "$IT_WINDOWS_EXTRA/*.msi" >/dev/null; }; then
        echo "$golden"
        return 0
    fi
    "$VMPANE_ROOT/itest/lib/build-golden-windows.sh" "$golden" >&2 || { status=$?; return "$status"; }
    echo "$golden"
}

# Saves a screenshot of the VM behind control socket $1 to PNG $2 (longest edge $3, default 800).
it_screenshot() {
    it_rpc "$1" vm.screenshot "{\"maxEdge\": ${3:-800}}" | jq -r '.dataB64 // empty' | base64 -d >"$2" && [[ -s $2 ]]
}

# Waits up to $2 s until the Windows guest behind socket $1 shows its desktop: two screenshots in a row,
# 3 s apart, with most of the screen lit (firmware, boot spinner and lock screen fade-in are mostly black).
# Windows blanks an idle display after ~10 min; a key press wakes it.
it_wait_windows_desktop() {
    local socket=$1 deadline=$((SECONDS + $2)) shot lit streak=0
    shot=$(mktemp /tmp/vp-shot.XXXXXX)
    while ((SECONDS < deadline)); do
        if it_screenshot "$socket" "$shot" 400 2>/dev/null && lit=$(it_png_lit_percent "$shot") && ((lit >= 40)); then
            ((++streak >= 2)) && { rm -f "$shot"; return 0; }
        else
            streak=0
        fi
        sleep 3
    done
    rm -f "$shot"
    return 1
}

# Fraction (0–100) of non-black pixels in PNG $1, sampled.
it_png_lit_percent() { it_png_lit "$1" 16 percent; }
# Number of non-black pixels in PNG $1 (every pixel: for text consoles).
it_png_lit_pixels() { it_png_lit "$1" 1 count; }

it_png_lit() {  # it_png_lit <png> <sample step> <percent|count>
    /usr/bin/python3 - "$1" "$2" "$3" <<'PY'
import sys, zlib, struct
data = open(sys.argv[1], "rb").read()
pos, chunks = 8, []
while pos < len(data):
    n, t = struct.unpack(">I4s", data[pos:pos+8]); body = data[pos+8:pos+8+n]; pos += 12 + n
    if t == b"IHDR": w, h, depth, ctype = struct.unpack(">IIBB", body[:10])
    if t == b"IDAT": chunks.append(body)
raw = zlib.decompress(b"".join(chunks)); bpp = 4 if ctype == 6 else 3; stride = w * bpp
# Undo the per-row PNG filters (8-bit RGB/RGBA), then sample every 16th pixel.
prev, rows = bytearray(stride), []
for y in range(h):
    f, line = raw[y * (stride + 1)], bytearray(raw[y * (stride + 1) + 1:(y + 1) * (stride + 1)])
    for i in range(stride):
        a = line[i - bpp] if i >= bpp else 0; b = prev[i]; c = prev[i - bpp] if i >= bpp else 0
        if f == 1: line[i] = (line[i] + a) & 255
        elif f == 2: line[i] = (line[i] + b) & 255
        elif f == 3: line[i] = (line[i] + (a + b) // 2) & 255
        elif f == 4:
            p = a + b - c; pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
            line[i] = (line[i] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
    rows.append(line); prev = line
step = int(sys.argv[2]); lit = total = 0
for y in range(0, h, step):
    for x in range(0, w, step):
        r, g, b = rows[y][x * bpp:x * bpp + 3]; total += 1; lit += (r + g + b) > 60
print(round(100 * lit / max(total, 1)) if sys.argv[3] == "percent" else lit)
PY
}

# Windows install scenarios. it_windows_iso: $VMPANE_WINDOWS_ISO, else the newest ~/Downloads/Win*arm64*.iso.
it_windows_iso() {
    local iso=${VMPANE_WINDOWS_ISO:-$(find "$HOME/Downloads" -maxdepth 1 -iname 'win*arm64*.iso' 2>/dev/null | sort | tail -1)}
    [[ -f $iso ]] && echo "$iso"
}

# it_windows_install_bundle <bundle> <iso> <tools iso> <request> <password> [locale]: a blank 64 GiB Windows VM,
# and the 0600 request for the helper's VMPANE_TEST_WIN_INSTALL hook (the wizard's step; locale: the Mac's, en-US).
it_windows_install_bundle() {
    local bundle=$1 iso=$2 tools=$3 request=$4 password=$5 locale=${6:-en-US}
    it_create_bundle "$bundle" windows \
        '.name = "win-install" | .backend = "qemu" | .cpu.count = 4 | .memory.mib = 4096 | .vz = null
         | .disks[0] |= (.bus = "nvme" | .sizeGiB = 64) | .audio.output = false
         | .qemu = {tpm: true, secureBoot: true, gpu: "ramfb", storageBus: "nvme", smbiosUUID: "'"$(uuidgen)"'"}
         | .windows = {}'
    mkfile -n 64g "$bundle/current/disk.img"
    chmod 600 "$bundle/current/disk.img"
    (umask 077 && jq -n --arg iso "$iso" --arg tools "$tools" --arg password "$password" --arg locale "$locale" '{
        iso: $iso, tools: $tools, locale: $locale, timeZone: "UTC", computerName: "VMPANE-IT",
        userName: "vmpane", password: $password, editionName: "Windows 11 Pro"}' >"$request")
}

# it_install_phase <bundle>: the phase in install/install.json ("unknown" without one).
it_install_phase() { jq -r .phase "$1/install/install.json" 2>/dev/null || echo unknown; }

# it_wait_install <bundle> <minutes>: follows install/install.json, printing each phase, until the install is done
# (0), or failed, cancelled or out of time (1).
it_wait_install() {
    local bundle=$1 start=$SECONDS phase last=''
    while ((SECONDS - start < $2 * 60)); do
        phase=$(it_install_phase "$bundle")
        [[ $phase != "$last" ]] && echo "$IT_SCENARIO: $phase after $(((SECONDS - start) / 60)) min" && last=$phase
        case $phase in
            done) return 0 ;;
            failed | cancelled) it_fail "install $phase: $(jq -r .reason "$bundle/install/install.json")"; return 1 ;;
        esac
        sleep 5
    done
    it_fail "the install did not finish within $2 min (at $phase)"
}
