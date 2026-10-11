#!/usr/bin/env bash
# Sign VMPane.app inside-out from Config/signing-manifest.json (never --deep).
# Usage: scripts/sign.sh [--dry-run|--verify] [--qemu-only] <VMPane.app | QEMU bundle>
#   (default)  sign with $VMPANE_SIGN_IDENTITY (default "-", ad hoc); the hardened runtime is on for real identities
#   --dry-run  print the plan
#   --verify   check identifiers and entitlements against the manifest, then `codesign --verify --strict`.
#              For non-ad hoc signatures also: hardened runtime, secure timestamp, one team ID throughout,
#              no get-task-allow (what notarization requires).
#   --qemu-only  the target is a QEMU bundle (qemu/scripts/package.sh): only the manifest items under
#              Contents/Helpers/qemu/ (mapped to the bundle root) and the helper's Frameworks/ (mapped to
#              frameworks/) apply.
# All modes fail when the bundle holds a Mach-O the manifest does not cover.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
manifest="$root/Config/signing-manifest.json"

mode=sign
case "${1:-}" in --dry-run) mode=dry; shift ;; --verify) mode=verify; shift ;; esac
qemu_only=false
[[ "${1:-}" == --qemu-only ]] && { qemu_only=true; shift; }
if (($# != 1)); then
    echo "usage: scripts/sign.sh [--dry-run|--verify] [--qemu-only] <VMPane.app | QEMU bundle>" >&2
    exit 2
fi
app=$1
app=$(cd "$app" && pwd)
identity=${VMPANE_SIGN_IDENTITY:--}

covered=$(mktemp)
trap 'rm -f "$covered"' EXIT
failures=0
teams=""

# Entitlements as sorted JSON. $2 = true drops get-task-allow (allowed on ad hoc development builds).
entitlements_json() {
    local xml
    xml=$(codesign -d --entitlements - --xml "$1" 2>/dev/null || true)
    if [[ -z "$xml" ]]; then echo '{}'; return; fi
    if [[ "$2" == true ]]; then
        plutil -convert json -o - - <<<"$xml" | jq -S -c 'del(."com.apple.security.get-task-allow")'
    else
        plutil -convert json -o - - <<<"$xml" | jq -S -c .
    fi
}

fail() {
    echo "FAIL $1" >&2
    failures=$((failures + 1))
}

expected_json() {
    if [[ "$1" == null ]]; then echo '{}'; else plutil -convert json -o - "$root/$1" | jq -S -c .; fi
}

count=$(jq '.items | length' "$manifest")
for ((i = 0; i < count; i++)); do
    item=$(jq -c ".items[$i]" "$manifest")
    pattern=$(jq -r .path <<<"$item")
    id=$(jq -r .identifier <<<"$item")
    ent=$(jq -r .entitlements <<<"$item")
    optional=$(jq -r '.optional // false' <<<"$item")
    if $qemu_only; then
        case "$pattern" in
            Contents/Helpers/qemu/*) pattern=${pattern#Contents/Helpers/qemu/} ;;
            Contents/Helpers/VMPaneVM.app/Contents/Frameworks/*) pattern=frameworks/${pattern##*/} ;;
            *) continue ;;
        esac
    fi

    if [[ "$pattern" == "." ]]; then
        targets=("$app")
    else
        shopt -s nullglob
        # shellcheck disable=SC2206 # the pattern is a glob on purpose
        matches=("$app"/$pattern)
        shopt -u nullglob
        # nullglob keeps a non-glob path even when it does not exist.
        targets=()
        for m in ${matches[@]+"${matches[@]}"}; do
            [[ -e "$m" ]] && targets+=("$m")
        done
    fi
    if ((${#targets[@]} == 0)); then
        if [[ "$optional" == true ]]; then continue; fi
        echo "error: required item missing: $pattern" >&2
        failures=$((failures + 1))
        continue
    fi

    for target in "${targets[@]}"; do
        rel=${target#"$app"/}
        [[ "$target" == "$app" ]] && rel=.
        if [[ "$target" == *.framework ]]; then
            echo "$target/Versions/$(readlink "$target/Versions/Current")/$(basename "$target" .framework)" >>"$covered"
        elif [[ -d "$target" ]]; then
            exe=$(plutil -extract CFBundleExecutable raw "$target/Contents/Info.plist")
            echo "$target/Contents/MacOS/$exe" >>"$covered"
        else
            echo "$target" >>"$covered"
        fi

        case "$mode" in
            dry)
                printf '%-60s id=%-36s entitlements=%s\n' "$rel" "$([[ $id == null ]] && echo '(default)' || echo "$id")" "$([[ $ent == null ]] && echo none || echo "$ent")"
                ;;
            sign)
                args=(--force --sign "$identity")
                # Ad hoc signatures have no team ID, so under the hardened runtime library validation would
                # refuse our own dylibs (Xcode also drops the runtime for ad hoc signing).
                if [[ "$identity" == - ]]; then
                    args+=(--timestamp=none)
                else
                    args+=(--timestamp --options runtime)
                fi
                [[ "$id" != null ]] && args+=(--identifier "$id")
                [[ "$ent" != null ]] && args+=(--entitlements "$root/$ent")
                # Quiet on success ("replacing existing signature"); show codesign's output on failure.
                if ! out=$(codesign "${args[@]}" "$target" 2>&1); then
                    echo "$out" >&2
                    exit 1
                fi
                ;;
            verify)
                info=$(codesign -dv "$target" 2>&1 || true)
                if ! grep -q '^Identifier=' <<<"$info"; then
                    fail "$rel: not signed"
                    continue
                fi
                adhoc=false
                grep -q '^CodeDirectory.*flags=.*adhoc' <<<"$info" && adhoc=true
                if [[ "$id" != null ]]; then
                    actual=$(sed -n 's/^Identifier=//p' <<<"$info")
                    [[ "$actual" == "$id" ]] || fail "$rel: identifier $actual, expected $id"
                fi
                got=$(entitlements_json "$target" "$adhoc")
                want=$(expected_json "$ent")
                [[ "$got" == "$want" ]] || fail "$rel: entitlements $got, expected $want"
                if [[ "$adhoc" == false ]]; then
                    grep -q '^CodeDirectory.*flags=.*runtime' <<<"$info" || fail "$rel: hardened runtime off"
                    grep -q '^Timestamp=' <<<"$info" || fail "$rel: no secure timestamp"
                    teams="$teams $(sed -n 's/^TeamIdentifier=//p' <<<"$info")"
                fi
                ;;
        esac
    done
done

# Coverage: every Mach-O in the bundle is a manifest item or the main executable of one.
while IFS= read -r -d '' f; do
    if [[ "$(file -b "$f")" == *Mach-O* ]] && ! grep -Fxq "$f" "$covered"; then
        fail "Mach-O not in signing manifest: ${f#"$app"/}"
    fi
done < <(find "$app" -type f -print0)

if [[ "$mode" == verify ]]; then
    unique_teams=$(tr ' ' '\n' <<<"$teams" | sed '/^$/d' | sort -u | wc -l | tr -d ' ')
    ((unique_teams <= 1)) || fail "more than one team ID in the bundle:$teams"
    if $qemu_only; then
        # A plain directory, not a bundle: check each signed file.
        while IFS= read -r f; do
            codesign --verify --strict "$f" || fail "codesign --verify --strict ${f#"$app"/}"
        done <"$covered"
    else
        codesign --verify --strict --deep "$app" || fail "codesign --verify --strict --deep"
    fi
fi

if ((failures)); then
    echo "sign ($mode): $failures problem(s)" >&2
    exit 1
fi
echo "sign ($mode): ok"
