#!/usr/bin/env bash
# Package a signed VMPane.app into a compressed DMG: the app beside an Applications link, on a background that
# says to drag one onto the other (Config/dmg, laid out by dmgbuild without driving Finder). Signs the DMG when
# $VMPANE_SIGN_IDENTITY is a real identity. Usage: scripts/make-dmg.sh <VMPane.app> [out.dmg]
set -euo pipefail

app=${1:?usage: scripts/make-dmg.sh <VMPane.app> [out.dmg]}
# A release always carries QEMU (Windows guests); a build without qemu/scripts/package.sh's bundle has none.
[[ -x "$app/Contents/Helpers/qemu/bin/qemu-system-aarch64" && -f "$app/Contents/Resources/qemu/share/edk2-aarch64-code.fd" ]] ||
    { echo "error: $app has no QEMU (build qemu/scripts/package.sh, then the app)" >&2; exit 1; }
[[ -f "$app/Contents/Resources/GuestTools/vmpane-guest-tools-windows.iso" ]] ||
    { echo "error: $app has no Windows guest tools (run guest-tools/build-iso.sh, then build the app)" >&2; exit 1; }
version=$(plutil -extract CFBundleShortVersionString raw "$app/Contents/Info.plist")
out=${2:-build/VMPane-$version.dmg}

# dmgbuild and its two dependencies, pinned by hash (Config/dmg/requirements.txt), in a venv of their own.
root=$(cd "$(dirname "$0")/.." && pwd)
venv=$root/build/tools/dmgbuild
if [[ ! -x $venv/bin/dmgbuild || $root/Config/dmg/requirements.txt -nt $venv/bin/dmgbuild ]]; then
    rm -rf "$venv"
    python=$(command -v /opt/homebrew/bin/python3 python3 | head -1)  # dmgbuild needs Python 3.10 or later
    "$python" -c 'import sys; sys.exit(sys.version_info < (3, 10))' \
        || { echo "error: dmgbuild needs Python 3.10 or later (brew install python)" >&2; exit 1; }
    "$python" -m venv "$venv"
    "$venv/bin/pip" install --quiet --disable-pip-version-check --require-hashes --no-deps --only-binary :all: \
        -r "$root/Config/dmg/requirements.txt"
fi

mkdir -p "$(dirname "$out")"
rm -f "$out"
"$venv/bin/dmgbuild" -s "$root/Config/dmg/settings.py" -D app="$app" -D here="$root/Config/dmg" "VMPane" "$out" >/dev/null
if [[ "${VMPANE_SIGN_IDENTITY:--}" != - ]]; then
    codesign --force --timestamp --sign "$VMPANE_SIGN_IDENTITY" "$out"
fi
echo "dmg: $out"
