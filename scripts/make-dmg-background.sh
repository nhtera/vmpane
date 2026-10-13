#!/usr/bin/env bash
# Renders Config/dmg/background.svg into the disk image's Retina background (1x and 2x in one TIFF).
# Needs rsvg-convert (brew install librsvg). Usage: scripts/make-dmg-background.sh
set -euo pipefail
dir=$(cd "$(dirname "$0")/../Config/dmg" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
rsvg-convert -w 540 -h 380 "$dir/background.svg" -o "$work/1x.png"
rsvg-convert -w 1080 -h 760 "$dir/background.svg" -o "$work/2x.png"
tiffutil -cathidpicheck "$work/1x.png" "$work/2x.png" -out "$dir/background.tiff" 2>/dev/null
echo "background: $dir/background.tiff"
