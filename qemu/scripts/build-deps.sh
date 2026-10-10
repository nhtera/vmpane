#!/usr/bin/env bash
# Builds the QEMU sysroot from qemu/deps.lock: fetch → verify SHA-256 → patch → build, in lock order.
# Tools go to qemu/build/tools (build-only), runtime components to qemu/build/stage/vmpane/qemu.
# A component is rebuilt when its lock entry, patches or recipe change (stamps in qemu/build/stamps),
# and everything after it in the lock is rebuilt too.
#
# Usage: qemu/scripts/build-deps.sh [--clean] [--fetch-only] [--until <component>]
#   --clean       remove everything built (downloads are kept; they are verified on use)
#   --fetch-only  download and verify every tarball, build nothing
#   --until <c>   stop after component <c>
set -euo pipefail
source "$(dirname "$0")/lib/env.sh"
source "$(dirname "$0")/lib/recipes.sh"

clean=false fetch_only=false until=
while (($#)); do
    case $1 in
        --clean) clean=true; shift ;;
        --fetch-only) fetch_only=true; shift ;;
        --until) until=${2:?--until needs a component}; shift 2 ;;
        *) die "usage: build-deps.sh [--clean] [--fetch-only] [--until <component>]" ;;
    esac
done
[[ -z $until ]] || lock_names | grep -qx "$until" || die "--until: no component $until in deps.lock"

if $fetch_only; then
    for name in $(lock_names); do fetch "$name" >/dev/null && echo "ok $name"; done
    exit 0
fi

check_xcode
$clean && rm -rf "$SRC" "$TOOLS" "$STAGE" "$STAMPS" "$LOGS"
mkdir -p "$SRC" "$TOOLS" "$STAGE" "$STAMPS" "$LOGS"
hermetic_env

# What a component's build depends on: its lock entry, patches and recipe, plus the previous key.
stamp_key() {
    local name=$1 previous=$2
    {
        echo "$previous"
        jq -c --arg n "$name" '.components[] | select(.name == $n)' "$LOCK"
        jq -c '{prefix, sourceDateEpoch, macosDeploymentTarget}' "$LOCK"
        declare -f "recipe_${name//-/_}"
        # The shared helpers (normalised by bash: comments and layout do not count).
        declare -f $(compgen -A function | grep -v '^recipe_')
        [[ $name == qemu ]] && cat "$QEMU_DIR/configs/devices-vmpane.mak"
        [[ $name == python ]] && cat "$QEMU_DIR/tools-requirements.txt"
        [[ -d $QEMU_DIR/patches/$name ]] && cat "$QEMU_DIR/patches/$name"/*
        echo "$COMMON_CFLAGS $COMMON_LDFLAGS"
    } | shasum -a 256 | cut -d' ' -f1
}

start=$SECONDS
key=
for name in $(lock_names); do
    recipe=recipe_${name//-/_}
    declare -F "$recipe" >/dev/null || die "$name: no recipe in lib/recipes.sh"
    key=$(stamp_key "$name" "$key")
    stamp=$STAMPS/$name
    if [[ -f $stamp && $(cat "$stamp") == "$key" ]]; then
        echo "up to date: $name"
    else
        rm -f "$stamp"
        log=$LOGS/$name.log
        echo "building: $name $(lock_get "$name" version)"
        t=$SECONDS
        # errexit is ignored inside `if` conditions, so the recipe runs as a plain command.
        set +e
        (
            set -e
            "$recipe"
        ) >"$log" 2>&1
        status=$?
        set -e
        if ((status)); then
            tail -30 "$log" >&2
            die "$name failed (log: $log)"
        fi
        echo "$key" >"$stamp"
        echo "  done in $((SECONDS - t)) s"
    fi
    [[ $name == "$until" ]] && break
done
# Every Mach-O in the sysroot may load only system libraries and sysroot libraries.
leaks=0
while IFS= read -r -d '' f; do
    file -b "$f" | grep -q Mach-O || continue
    while read -r lib; do
        echo "outside the sysroot: ${f#"$SYSROOT"/} -> $lib" >&2
        leaks=$((leaks + 1))
    done < <(otool -L "$f" | tail -n +2 | awk '{print $1}' | grep -v -E "^(/usr/lib/|/System/|$PREFIX/lib/|@rpath/)" || true)
done < <(find "$SYSROOT" -type f -print0)
((leaks == 0)) || die "$leaks load path(s) outside the sysroot"
echo "build-deps: done in $((SECONDS - start)) s"
