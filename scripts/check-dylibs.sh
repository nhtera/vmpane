#!/usr/bin/env bash
# Every Mach-O in the app may link only system libraries or libraries inside the bundle, and may carry
# only bundle-relative run paths. Catches leaked build or Homebrew paths before notarization does.
# Rules: LC_RPATH entries start with @loader_path/, @executable_path/ or are /usr/lib/swift; libraries
# are system paths or resolve inside the bundle; dylibs use @loader_path or @rpath, not @executable_path.
# Debug builds carry absolute run paths into DerivedData, so run this on Release builds.
# Usage: scripts/check-dylibs.sh <VMPane.app>
set -euo pipefail

app=${1:?usage: scripts/check-dylibs.sh <VMPane.app>}
failures=0
fail() {
    echo "$1" >&2
    failures=$((failures + 1))
}

while IFS= read -r -d '' f; do
    kind=$(file -b "$f")
    [[ "$kind" == *Mach-O* ]] || continue
    rel=${f#"$app"/}
    dir=$(dirname "$f")
    is_dylib=false
    [[ "$kind" == *"dynamically linked shared library"* ]] && is_dylib=true

    # Run paths, with @loader_path / @executable_path expanded against this file (for executables the two agree).
    rpaths=()
    while read -r rp; do
        case "$rp" in
            @loader_path/* | @executable_path/*) rpaths+=("$dir/${rp#*/}") ;;
            @loader_path | @executable_path) rpaths+=("$dir") ;;
            /usr/lib/swift) rpaths+=("$rp") ;;
            *) fail "absolute run path: $rel -> $rp" ;;
        esac
    done < <(otool -l "$f" | awk '$1 == "cmd" && $2 == "LC_RPATH" {getline; getline; print $2}')

    own_id=$($is_dylib && otool -D "$f" | tail -n +2 | head -1 || true)
    # Skip otool's "<file>:" / "<file> (architecture …):" header lines.
    while read -r lib; do
        [[ "$lib" == "$own_id" ]] && continue
        case "$lib" in
            /usr/lib/* | /System/*) ;;
            @loader_path/*)
                [[ -e "$dir/${lib#*/}" ]] || fail "missing: $rel -> $lib" ;;
            @executable_path/*)
                if $is_dylib; then
                    fail "dylib uses @executable_path (use @loader_path or @rpath): $rel -> $lib"
                elif [[ ! -e "$dir/${lib#*/}" ]]; then
                    fail "missing: $rel -> $lib"
                fi
                ;;
            @rpath/*)
                name=${lib#@rpath/}
                found=false
                for rp in ${rpaths[@]+"${rpaths[@]}"}; do
                    # The Swift runtime lives in the shared cache, not on disk.
                    if [[ "$rp" == /usr/lib/swift && "$name" == libswift* ]] || [[ -e "$rp/$name" ]]; then
                        found=true
                        break
                    fi
                done
                $found || fail "unresolved: $rel -> $lib"
                ;;
            *) fail "outside bundle: $rel -> $lib" ;;
        esac
    done < <(otool -L "$f" | grep -v ':$' | awk '{print $1}')
done < <(find "$app" -type f -print0)

if ((failures)); then
    echo "check-dylibs: $failures problem(s)" >&2
    exit 1
fi
echo "check-dylibs: ok"
