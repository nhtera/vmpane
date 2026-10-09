#!/usr/bin/env bash
# Package a signed VMPane.app into a compressed DMG with an Applications link; signs the DMG when
# $VMPANE_SIGN_IDENTITY is a real identity. Usage: scripts/make-dmg.sh <VMPane.app> [out.dmg]
set -euo pipefail

app=${1:?usage: scripts/make-dmg.sh <VMPane.app> [out.dmg]}
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
