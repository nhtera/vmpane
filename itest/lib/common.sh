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
    it_wait_for 10 test -S "$run/$sid.sock" || { it_fail "helper for $bundle did not bind its socket"; return 1; }
    echo "$pid"
}

it_socket() { echo "$VMPANE_SUPPORT_DIR/run/$(it_sid "$1").sock"; }

# The golden Linux bundle (Ubuntu cloud image, cloud-init done, prints markers on the serial console).
# Built once into ~/VMPaneItest/linux-base.vmpane; scenarios clone it.
it_golden_linux() {
    local golden="$HOME/VMPaneItest/linux-base.vmpane"
    if [[ -f "$golden/.ready" ]]; then echo "$golden"; return 0; fi
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
