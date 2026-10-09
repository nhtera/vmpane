#!/usr/bin/env bash
# Install the tools pinned in scripts/tools.lock into build/tools (idempotent; verifies sha256).
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
tools="$root/build/tools"
mkdir -p "$tools/bin"

grep -v '^#' "$root/scripts/tools.lock" | while read -r name version exe url sha; do
    [[ -n "$name" ]] || continue
    dir="$tools/$name-$version"
    if [[ ! -f "$dir/.installed" ]]; then
        tmp=$(mktemp -d)
        curl -fsSL -o "$tmp/archive.zip" "$url"
        if [[ "$(shasum -a 256 "$tmp/archive.zip" | awk '{print $1}')" != "$sha" ]]; then
            echo "error: $name $version: sha256 mismatch for $url" >&2
            rm -rf "$tmp"
            exit 1
        fi
        rm -rf "$dir"
        mkdir -p "$dir"
        ditto -x -k "$tmp/archive.zip" "$dir"
        rm -rf "$tmp"
        touch "$dir/.installed"
        echo "installed $name $version"
    fi
    # A wrapper, not a symlink: xcodegen finds its share/ folder relative to the path it was started from.
    rm -f "$tools/bin/$name"
    printf '#!/bin/sh\nexec "%s" "$@"\n' "$dir/$exe" >"$tools/bin/$name"
    chmod +x "$tools/bin/$name"
done
