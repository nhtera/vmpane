# Performance pass (Phase 11): the plan's targets, measured on this Mac, recorded in the scenario's result
# (`metrics`) and compared with itest/perf-baseline.json for this chip: a metric more than 15% (and more than
# its noise floor) worse than its baseline, or past its target, fails. VMPANE_PERF_RECORD=1 writes this run as the chip's baseline instead.
# Windows metrics need the Windows golden (skipped, not failed, without it).
# Sourced by scripts/itest.sh with $APP set.

source "$VMPANE_ROOT/itest/lib/common.sh"
IT_SCENARIO=perf

it_agent_exec() { /usr/bin/python3 "$VMPANE_ROOT/itest/lib/agent_exec.py" "$socket" "$@"; }
it_agent_connected() { [[ $(it_rpc "$socket" agent.status | jq -r .connected) == true ]]; }
it_now() { /usr/bin/python3 -c 'import time; print(time.time())'; }
it_since() { /usr/bin/python3 -c "import time; print(round(time.time() - $1, 3))"; }

metrics='{}'
# perf_record <name> <value>
perf_record() {
    metrics=$(jq -c --arg k "$1" --argjson v "$2" '. + {($k): $v}' <<<"$metrics")
    echo "perf: $1 = $2"
}

# The app's launch with 20 VMs in its library, to the library's first listing (its log line).
perf_app_launch() {
    local support exe stream start pid i
    support=$(mktemp -d /tmp/vp-perf.XXXXXX)
    export VMPANE_SUPPORT_DIR="$support/s"
    mkdir -p "$VMPANE_SUPPORT_DIR/VMs"
    for i in $(seq 1 20); do it_create_bundle "$VMPANE_SUPPORT_DIR/VMs/V$i.vmpane"; done
    exe="$APP/Contents/MacOS/$(plutil -extract CFBundleExecutable raw "$APP/Contents/Info.plist")"
    log stream --style ndjson --predicate 'subsystem == "app.vmpane.mac" AND category == "library"' >"$support/log" 2>/dev/null &
    stream=$!
    sleep 1
    start=$(it_now)
    "$exe" >/dev/null 2>&1 &
    pid=$!
    local listed=0
    if it_wait_for 20 grep -q 'library listed 20 VMs' "$support/log"; then
        # The app's own count from its process start (the log's delivery adds a little).
        perf_record appLaunchMs "$(grep -o 'library listed 20 VMs [0-9]* ms' "$support/log" | head -1 | awk '{print $5}')"
    else
        it_fail "the app did not list its 20 VMs within 20 s" || listed=1
    fi
    kill -TERM "$pid" 2>/dev/null || true
    it_wait_exit "$pid" 10 || kill -KILL "$pid" 2>/dev/null || true
    kill "$stream" 2>/dev/null || true
    rm -rf "$support"
    return $listed
}

# Both use scenario_run's work, bundle, pid and socket, so its trap cleans up after a failure.
perf_linux() {
    local start seconds guest host
    start=$(it_now)
    it_boot_linux_clone || return 1
    perf_record linuxBootS "$(it_since "$start")"

    it_rpc "$socket" vm.input.text '{"text": "VMPANE-INSTALL-AGENT\n"}' >/dev/null
    it_wait_for 60 grep -qa 'VMPANE-AGENT-INSTALLED rc=0' "$bundle/logs/serial.log" || it_fail "the agent did not install" || return 1
    it_wait_for 30 it_agent_connected || it_fail "the agent did not connect" || return 1

    perf_record screenshotMs "$(it_rpc "$socket" vm.screenshot '{"maxEdge": 1568}' --repeat 10)"
    perf_record helperRSSMB "$(($(ps -o rss= -p "$pid") / 1024))"

    # A 256 MiB download through a loopback forward.
    it_agent_exec 'mkdir -p /root/www && head -c 268435456 /dev/urandom >/root/www/big.bin
        setsid -f python3 -m http.server 8000 --directory /root/www >/dev/null 2>&1 </dev/null; sleep 1' >/dev/null
    local port=$((20000 + RANDOM % 20000))
    it_rpc "$socket" vm.settings.apply "$(jq -nc --argjson p "$port" '{patch: {portForwards: [
        {id: "web", proto: "tcp", hostAddress: "127.0.0.1", hostPort: $p, guestPort: 8000, origin: "user"}]}}')" >/dev/null \
        || it_fail "the forward did not apply" || return 1
    curl -sf --max-time 30 "http://127.0.0.1:$port/big.bin" -o /dev/null || true  # warm the guest's cache
    start=$(it_now)
    curl -sf --max-time 60 "http://127.0.0.1:$port/big.bin" -o /dev/null || it_fail "the download failed" || return 1
    seconds=$(it_since "$start")
    perf_record forwardMbps "$(/usr/bin/python3 -c "print(int(268435456 * 8 / $seconds / 1e6))")"

    # Sequential read: the guest reading 1 GiB of its disk after dropping its caches, against this Mac's SSD
    # reading a fresh 1 GiB file uncached (F_NOCACHE), both in 4 MiB requests.
    guest=$(it_agent_exec 'sync; echo 3 >/proc/sys/vm/drop_caches; dd if=/dev/vda of=/dev/null bs=4M count=256 2>&1 | tail -1' \
        | /usr/bin/python3 -c 'import re, sys
m = re.search(r"([\d.]+) ([GM])B/s", sys.stdin.read())
print(float(m.group(1)) * (1000 if m.group(2) == "G" else 1))')
    host=$(/usr/bin/python3 - "$work/read.bin" <<'EOF'
import fcntl, os, sys, time
F_NOCACHE = 48
fd = os.open(sys.argv[1], os.O_RDWR | os.O_CREAT, 0o600)
fcntl.fcntl(fd, F_NOCACHE, 1)
block = os.urandom(4 << 20)
for _ in range(256):
    os.write(fd, block)
os.fsync(fd)
os.lseek(fd, 0, 0)
start, total = time.time(), 0
while True:
    chunk = os.read(fd, 4 << 20)
    if not chunk:
        break
    total += len(chunk)
print(total / (time.time() - start) / 1e6)
os.unlink(sys.argv[1])
EOF
)
    echo "perf: guest reads $guest MB/s, this Mac's SSD $host MB/s"
    perf_record guestReadRatio "$(/usr/bin/python3 -c "print(round($guest / $host, 2))")"

    # A disk-only snapshot of the stopped VM.
    it_rpc "$socket" vm.stop '{"mode": "force"}' >/dev/null || it_fail "vm.stop failed" || return 1
    it_wait_for 30 bash -c "[[ \$(/usr/bin/python3 '$VMPANE_ROOT/itest/lib/rpc.py' '$socket' vm.info | jq -r .state) == stopped ]]" \
        || it_fail "the VM did not stop" || return 1
    start=$(it_now)
    it_rpc "$socket" vm.snapshot.create '{"name": "perf", "kind": "disk"}' >/dev/null || it_fail "the snapshot failed" || return 1
    perf_record diskSnapshotS "$(it_since "$start")"
    it_rpc "$socket" helper.shutdown >/dev/null
    it_wait_exit "$pid" 30 || true
    pid=
    rm -rf "$work"
    work=
}

perf_windows() {
    local golden start status children
    golden=$(it_golden_windows) || { status=$?; return "$status"; }
    work=$(cd "$(mktemp -d /tmp/vp-pw.XXXXXX)" && pwd -P)
    export VMPANE_SUPPORT_DIR="$work/s"
    mkdir -p "$VMPANE_SUPPORT_DIR/VMs"
    bundle="$VMPANE_SUPPORT_DIR/VMs/W.vmpane"
    it_clone_bundle "$golden" "$bundle"
    pid=$(it_start_helper "$bundle") || return 1
    socket=$(it_socket "$bundle")
    start=$(it_now)
    it_rpc "$socket" vm.start '{"headless": true}' >/dev/null || it_fail "vm.start failed" || return 1
    it_wait_windows_desktop "$socket" 120 || it_fail "no desktop within 120 s" || return 1
    perf_record windowsBootS "$(it_since "$start")"
    # Idle: the helper, QEMU and swtpm together, 60 s after the desktop, over 30 s (percent of one core).
    sleep 60
    children=$(jq -r .process.pid "$VMPANE_SUPPORT_DIR/run/"*.children | paste -sd' ' -)
    perf_record windowsIdleCPU "$(/usr/bin/python3 - "$pid" $children <<'EOF'
import subprocess, sys, time
def cpu_seconds(pids):
    total = 0.0
    for line in subprocess.run(["ps", "-o", "time=", "-p", ",".join(pids)], capture_output=True, text=True).stdout.split():
        parts = [float(p) for p in line.split(":")]
        total += sum(v * 60 ** i for i, v in enumerate(reversed(parts)))
    return total
pids = sys.argv[1:]
before, start = cpu_seconds(pids), time.time()
time.sleep(30)
print(round((cpu_seconds(pids) - before) / (time.time() - start) * 100, 1))
EOF
)"
    it_rpc "$socket" vm.stop '{"mode": "force"}' >/dev/null
    it_rpc "$socket" helper.shutdown >/dev/null
    it_wait_exit "$pid" 30 || true
    pid=
    rm -rf "$work"
    work=
}

# Targets from the plan (lower is better unless the name says otherwise).
perf_targets='{"appLaunchMs": 1000, "linuxBootS": 20, "screenshotMs": 300, "helperRSSMB": 150, "forwardMbps": 1000,
    "guestReadRatio": 0.7, "diskSnapshotS": 2, "windowsBootS": 90, "windowsIdleCPU": 15}'
perf_higher_is_better='["forwardMbps", "guestReadRatio"]'
# Run-to-run noise: a change smaller than this is not a regression, whatever its percentage.
perf_noise='{"appLaunchMs": 150, "linuxBootS": 2, "screenshotMs": 20, "helperRSSMB": 20, "forwardMbps": 8000,
    "guestReadRatio": 0.15, "diskSnapshotS": 0.5, "windowsBootS": 10, "windowsIdleCPU": 3}'

scenario_run() {
    local chip baseline_file="$VMPANE_ROOT/itest/perf-baseline.json" status=0 failures work= bundle= pid= socket=
    trap 'set +e; [[ -n ${pid:-} ]] && kill -TERM "$pid" 2>/dev/null && { it_wait_exit "$pid" 60 || kill -9 "$pid"; }
          [[ -n ${work:-} ]] && rm -rf "$work"; true' RETURN
    chip=$(sysctl -n machdep.cpu.brand_string)
    perf_app_launch || return 1
    perf_linux || return 1
    perf_windows || { status=$?; [[ $status == 77 ]] && echo "perf: Windows metrics skipped (no Windows golden)" || return 1; }
    [[ -n ${IT_METRICS_FILE:-} ]] && echo "$metrics" >"$IT_METRICS_FILE"

    if [[ ${VMPANE_PERF_RECORD:-} == 1 ]]; then
        local current='{}'
        [[ -f $baseline_file ]] && current=$(cat "$baseline_file")
        jq --arg chip "$chip" --argjson m "$metrics" '.[$chip] = ((.[$chip] // {}) + $m)' <<<"$current" >"$baseline_file"
        echo "perf: recorded as the baseline for $chip"
    fi
    failures=$(jq -nr --arg chip "$chip" --argjson m "$metrics" --argjson t "$perf_targets" --argjson up "$perf_higher_is_better" --argjson noise "$perf_noise" \
        --slurpfile b <(cat "$baseline_file" 2>/dev/null || echo '{}') '
        ($b[0][$chip] // {}) as $base
        | $m | to_entries[] | .key as $k | .value as $v | ($up | index($k) != null) as $higher
        | (if $t[$k] == null then empty
           elif ($higher and $v < $t[$k]) or ((($higher | not)) and $v > $t[$k]) then "\($k) = \($v): past the target \($t[$k])"
           else empty end),
          (if $base[$k] == null then empty
           elif (($v - $base[$k]) | fabs) <= ($noise[$k] // 0) then empty
           elif ($higher and $v < $base[$k] * 0.85) or ((($higher | not)) and $v > $base[$k] * 1.15)
           then "\($k) = \($v): more than 15% worse than the baseline \($base[$k])" else empty end)')
    [[ -z $failures ]] || { it_fail "$failures"; return 1; }
    jq -e --arg chip "$chip" '.[$chip]' "$baseline_file" >/dev/null 2>&1 \
        || echo "perf: no baseline for $chip yet (VMPANE_PERF_RECORD=1 records one)"
    [[ $status == 77 ]] && return 77
    return 0
}
