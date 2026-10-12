#!/usr/bin/env bash
# Integration tests on a local Apple-silicon Mac (hosted CI cannot run nested VMs).
# Usage: scripts/itest.sh <scenario|all> [--app <VMPane.app|.dmg|.zip>] [--allow-skip]
# Each scenario file in itest/scenarios/ defines `scenario_run`, which returns 0 (pass), 77 (skipped)
# or anything else (fail). Results go to itest/results/<artifactSha256>-<scenario>-<chip>-<macOSBuild>.json;
# skipped never counts as a pass: the run exits non-zero unless --allow-skip is given.
# A .dmg or .zip is hashed as the file itself, then opened so scenarios get the .app inside.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
export VMPANE_ROOT=$root

scenario=${1:?usage: scripts/itest.sh <scenario|all> [--app <path>]}
shift
APP=build/Debug/VMPane.app
allow_skip=0
while (($#)); do
    case "$1" in
        --app) APP=$2; shift 2 ;;
        --allow-skip) allow_skip=1; shift ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

# The itests' way into helpers (signed app.vmpane.mac.itest, honoured only by ad hoc helpers; itest/bridge).
bridge=build/itest-bridge/vmpane-itest-bridge
if [[ ! -x $bridge || itest/bridge/main.swift -nt $bridge ]]; then
    mkdir -p "$(dirname "$bridge")"
    swiftc -O -o "$bridge" itest/bridge/main.swift
    codesign -s - -f -i app.vmpane.mac.itest "$bridge" 2>/dev/null
fi
export VMPANE_ITEST_BRIDGE=$root/$bridge
# Helpers signed with a Developer ID never honour the bridge: against such an app the tests act as an agent, within
# a policy set the way the app sets it (itest/policy; common.sh it_signed).
swift build -q -c release --package-path itest/policy --scratch-path build/itest-policy
export VMPANE_ITEST_POLICY=$root/build/itest-policy/release/vmpane-itest-policy

if [[ "$(uname -m)" != arm64 ]]; then
    echo "error: itests need an Apple-silicon Mac" >&2
    exit 1
fi
[[ -e "$APP" ]] || { echo "error: no artifact at $APP (run scripts/build.sh Debug)" >&2; exit 1; }
APP=$(cd "$(dirname "$APP")" && pwd)/$(basename "$APP")

# A bundle is hashed by content (sorted per-file hashes, C locale) so a copy keeps its identity.
if [[ -d "$APP" ]]; then
    artifact_sha=$(cd "$APP" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256 | shasum -a 256 | awk '{print $1}')
else
    artifact_sha=$(shasum -a 256 "$APP" | awk '{print $1}')
fi

open_dir=""
cleanup() {
    [[ -n "$open_dir" ]] || return 0
    [[ -d "$open_dir/mnt" ]] && hdiutil detach -quiet "$open_dir/mnt" 2>/dev/null
    rm -rf "$open_dir"
}
trap cleanup EXIT
case "$APP" in
    *.dmg)
        open_dir=$(mktemp -d)
        hdiutil attach -quiet -nobrowse -readonly -mountpoint "$open_dir/mnt" "$APP"
        APP="$open_dir/mnt/VMPane.app"
        ;;
    *.zip)
        open_dir=$(mktemp -d)
        ditto -x -k "$APP" "$open_dir"
        APP="$open_dir/VMPane.app"
        ;;
esac
[[ -d "$APP" ]] || { echo "error: no VMPane.app in the artifact" >&2; exit 1; }
export APP
team=$(codesign -dv "$APP" 2>&1 | sed -n 's/^TeamIdentifier=//p')
export VMPANE_ITEST_SIGNED=$([[ -n $team && $team != "not set" ]] && echo 1 || echo 0)
git_sha=$(git rev-parse --verify -q HEAD || echo none)
dirty=$([[ -n "$(git status --porcelain 2>/dev/null)" ]] && echo true || echo false)
chip=$(sysctl -n machdep.cpu.brand_string | tr ' ' '-')
macos_build=$(sw_vers -buildVersion)

if [[ "$scenario" == all ]]; then
    scenarios=()
    for f in itest/scenarios/*.sh; do scenarios+=("$(basename "$f" .sh)"); done
else
    scenarios=("$scenario")
fi

mkdir -p itest/results
failed=0
skipped=0
for name in "${scenarios[@]}"; do
    file=itest/scenarios/$name.sh
    [[ -f "$file" ]] || { echo "error: no scenario $file" >&2; exit 2; }
    start=$(date +%s)
    helpers_before=$(pgrep -f 'VMPaneVM.app/Contents/MacOS/VMPaneVM' | sort || true)
    # A scenario may record measurements here (a JSON object); they go into its result.
    export IT_METRICS_FILE="$PWD/itest/results/.metrics-$name.json"
    rm -f "$IT_METRICS_FILE"
    set +e
    (
        set -euo pipefail
        # shellcheck source=/dev/null
        source "$file"
        scenario_run
    )
    rc=$?
    set -e
    # A scenario must not leave helpers (and their VMs) running: report, stop them, and fail it.
    leaked=$(comm -13 <(echo "$helpers_before") <(pgrep -f 'VMPaneVM.app/Contents/MacOS/VMPaneVM' | sort || true) | sed '/^$/d')
    if [[ -n $leaked ]]; then
        echo "itest $name: leaked helper(s): $(echo $leaked)" >&2
        kill -TERM $leaked 2>/dev/null || true
        sleep 3
        kill -KILL $leaked 2>/dev/null || true
        [[ $rc == 0 ]] && rc=1
    fi
    duration=$(($(date +%s) - start))
    case $rc in 0) result=pass ;; 77) result=skipped; skipped=1 ;; *) result=fail; failed=1 ;; esac

    out="itest/results/$artifact_sha-$name-$chip-$macos_build.json"
    jq -n --arg sha "$artifact_sha" --arg git "$git_sha" --argjson dirty "$dirty" --arg scenario "$name" \
        --arg result "$result" --argjson duration "$duration" --arg build "$macos_build" --arg chip "$chip" \
        '{artifactSha256: $sha, gitSha: $git, dirty: $dirty, scenario: $scenario, result: $result,
          durationS: $duration, macOSBuild: $build, chip: $chip}' >"$out"
    if [[ -s $IT_METRICS_FILE ]]; then
        jq --slurpfile m "$IT_METRICS_FILE" '. + {metrics: $m[0]}' "$out" >"$out.tmp" && mv "$out.tmp" "$out"
    fi
    rm -f "$IT_METRICS_FILE"
    echo "itest $name: $result (${duration}s) -> $out"
done
if ((failed)); then exit 1; fi
if ((skipped && !allow_skip)); then
    echo "itest: some scenarios were skipped (pass --allow-skip to accept)" >&2
    exit 1
fi
