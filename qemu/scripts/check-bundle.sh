#!/usr/bin/env bash
# Checks a QEMU bundle against qemu/bundle-manifest.json, the manifest a build of the committed inputs must
# produce: its MANIFEST.json must be identical (same components and pre-signing hashes, so the build was
# reproducible), and every file must match its as-shipped hash, with no file missing or added.
# CI runs it on every bundle it builds; scripts/fetch-qemu-bundle.sh runs it on every bundle it downloads.
# Usage: qemu/scripts/check-bundle.sh <bundle dir>
set -euo pipefail
source "$(dirname "$0")/lib/env.sh"

bundle=${1:?usage: check-bundle.sh <bundle dir>}
expected=$QEMU_DIR/bundle-manifest.json
[[ -f $expected ]] || die "no $expected"
[[ -f $bundle/MANIFEST.json ]] || die "no MANIFEST.json in $bundle"
if ! diff <(jq -S . "$expected") <(jq -S . "$bundle/MANIFEST.json") >&2; then
    die "$bundle/MANIFEST.json differs from qemu/bundle-manifest.json (different inputs, or the build is not reproducible)"
fi
actual=$(cd "$bundle" && find . ! -type d ! -name MANIFEST.json | sed 's|^\./||' | LC_ALL=C sort |
    while read -r f; do printf '%s %s\n' "$f" "$(shasum -a 256 "$f" | cut -d' ' -f1)"; done)
if ! diff <(jq -r '.signed | to_entries[] | "\(.key) \(.value)"' "$expected" | LC_ALL=C sort) <(echo "$actual") >&2; then
    die "files in $bundle differ from qemu/bundle-manifest.json"
fi
echo "check-bundle: $bundle matches qemu/bundle-manifest.json ($(jq '.signed | length' "$expected") files)"
