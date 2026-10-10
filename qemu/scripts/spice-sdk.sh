#!/usr/bin/env bash
# Generates Packages/VMPaneSpice/SpiceSDK from the build: the headers the vendored CocoaSpice includes (copied
# from the sysroot, include layout kept, so glib's relative includes resolve) and text stubs (.tbd) for the
# SPICE client libraries it calls (from the packaged bundle's frameworks/). The helper compiles against these
# and weak-links the stubs, so VMPane.app builds without the QEMU bundle; the libraries themselves ship in
# VMPaneVM.app/Contents/Frameworks. Committed; CI regenerates them after a clean build and fails on a diff
# (--check), so they cannot drift from what ships. Never hand-edit.
# Usage: qemu/scripts/spice-sdk.sh [--check] [--bundle <dir>]   (after build-deps.sh and package.sh)
set -euo pipefail
source "$(dirname "$0")/lib/env.sh"

check=0
bundle=$REPO_DIR/build/qemu-bundle
while (($#)); do
    case "$1" in
        --check) check=1; shift ;;
        --bundle) bundle=$2; shift 2 ;;
        *) echo "usage: spice-sdk.sh [--check] [--bundle <dir>]" >&2; exit 2 ;;
    esac
done
package=$REPO_DIR/Packages/VMPaneSpice
[[ -d $SYSROOT/include/spice-client-glib-2.0 ]] || { echo "spice-sdk: no SPICE client in $SYSROOT (build-deps.sh)" >&2; exit 1; }
[[ -d $bundle/frameworks ]] || { echo "spice-sdk: no $bundle/frameworks (package.sh)" >&2; exit 1; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
out=$work/SpiceSDK

# 1. Headers: every sysroot header the CocoaSpice sources include (compiler dependency output). The renderer
# is imported as a module, as SwiftPM builds it.
cat >"$work/module.modulemap" <<MAP
module CocoaSpiceRenderer {
    umbrella header "$package/Sources/CocoaSpiceRenderer/include/CocoaSpiceRenderer.h"
    export *
}
MAP
include=(-fmodule-map-file="$work/module.modulemap" -I"$SYSROOT/include" -I"$SYSROOT/include/glib-2.0" -I"$SYSROOT/lib/glib-2.0/include" -I"$SYSROOT/include/spice-1"
    -I"$SYSROOT/include/spice-client-glib-2.0" -I"$SYSROOT/include/pixman-1"
    -I"$package/Sources/CocoaSpice/include" -I"$package/Sources/CocoaSpiceRenderer/include" -I"$package/Sources/CocoaSpiceRenderer")
for source in "$package"/Sources/CocoaSpice/*.m; do
    xcrun clang -x objective-c -w -fmodules -fobjc-arc -fsyntax-only -MD -MF "$work/$(basename "$source").d" \
        -fmodules-cache-path="$work/modules" "${include[@]}" "$source"
done
cat "$work"/*.d | tr ' \\' '\n\n' | grep "^$SYSROOT/" | sed "s|^$SYSROOT/||" | sort -u >"$work/headers"
while read -r header; do
    mkdir -p "$out/$(dirname "$header")"
    cp "$SYSROOT/$header" "$out/$header"
done <"$work/headers"

# 2. Stubs: each framework library that exports a symbol the CocoaSpice objects need.
for source in "$package"/Sources/CocoaSpice/*.m "$package"/Sources/CocoaSpiceRenderer/*.m; do
    xcrun clang -x objective-c -w -fmodules -fobjc-arc -c -o "$work/$(basename "$source").o" \
        -fmodules-cache-path="$work/modules" "${include[@]}" "$source"
done
nm -u "$work"/*.o | grep -v ':$' | sort -u >"$work/undefined"
mkdir -p "$out/stubs"
for dylib in "$bundle"/frameworks/*.dylib; do
    nm -gU "$dylib" | awk '{print $3}' | sort -u >"$work/exports"
    if [[ -n $(comm -12 "$work/undefined" "$work/exports") ]]; then
        xcrun tapi stubify --filetype=tbd-v4 "$dylib" -o "$out/stubs/$(basename "$dylib" .dylib).tbd"
    fi
done

if ((check)); then
    diff -r "$out" "$package/SpiceSDK" >/dev/null || {
        diff -r "$out" "$package/SpiceSDK" | head -20
        echo "spice-sdk: Packages/VMPaneSpice/SpiceSDK differs from this build (rerun qemu/scripts/spice-sdk.sh)" >&2
        exit 1
    }
    echo "spice-sdk: up to date"
    exit 0
fi
rm -rf "$package/SpiceSDK"
cp -R "$out" "$package/SpiceSDK"
echo "spice-sdk: $(wc -l <"$work/headers" | tr -d ' ') headers, stubs: $(ls "$out/stubs" | tr '\n' ' ')"
