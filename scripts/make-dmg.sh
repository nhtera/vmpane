#!/usr/bin/env bash
# Package a signed VMPane.app into a compressed DMG with an Applications link; signs the DMG when
# $VMPANE_SIGN_IDENTITY is a real identity. Usage: scripts/make-dmg.sh <VMPane.app> [out.dmg]
set -euo pipefail

app=${1:?usage: scripts/make-dmg.sh <VMPane.app> [out.dmg]}
# A release always carries QEMU (Windows guests); a build without qemu/scripts/package.sh's bundle has none.
[[ -x "$app/Contents/Helpers/qemu/bin/qemu-system-aarch64" && -f "$app/Contents/Resources/qemu/share/edk2-aarch64-code.fd" ]] ||
    { echo "error: $app has no QEMU (build qemu/scripts/package.sh, then the app)" >&2; exit 1; }
version=$(plutil -extract CFBundleShortVersionString raw "$app/Contents/Info.plist")
out=${2:-build/VMPane-$version.dmg}

stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
ditto "$app" "$stage/VMPane.app"
ln -s /Applications "$stage/Applications"

mkdir -p "$(dirname "$out")"
hdiutil create -volname "VMPane $version" -srcfolder "$stage" -fs APFS -format ULFO -ov "$out" >/dev/null
if [[ "${VMPANE_SIGN_IDENTITY:--}" != - ]]; then
    codesign --force --timestamp --sign "$VMPANE_SIGN_IDENTITY" "$out"
fi
echo "dmg: $out"
