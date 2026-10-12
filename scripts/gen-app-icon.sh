#!/usr/bin/env bash
# Render the app icon set (App/Assets.xcassets/AppIcon.appiconset) from its master, Config/AppIcon.svg.
# Needs rsvg-convert (Brewfile: librsvg). Run after editing the master and commit the PNGs it writes.
# Usage: scripts/gen-app-icon.sh
set -euo pipefail
cd "$(dirname "$0")/.."

master=Config/AppIcon.svg
out=App/Assets.xcassets/AppIcon.appiconset
command -v rsvg-convert >/dev/null || { echo "error: rsvg-convert not found (brew install librsvg)" >&2; exit 1; }

# macOS sizes in points, each at 1x and 2x.
for pt in 16 32 128 256 512; do
    rsvg-convert -w "$pt" -h "$pt" "$master" -o "$out/icon_${pt}x${pt}.png"
    rsvg-convert -w $((pt * 2)) -h $((pt * 2)) "$master" -o "$out/icon_${pt}x${pt}@2x.png"
done
echo "gen-app-icon: $out"
