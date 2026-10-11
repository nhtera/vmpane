#!/usr/bin/env bash
# Downloads the agent MSI the Windows CI job built for a commit (default: the newest successful run on main)
# into build/guest-tools/windows-extra/, where guest-tools/build-iso.sh (VMPANE_GUEST_TOOLS_EXTRA) and the
# Windows golden build pick it up. Development builds only: releases build their own.
# Usage: guest-tools/fetch-agent-msi.sh [run-id]
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
out="$root/build/guest-tools/windows-extra"
run=${1:-$(gh run list --branch main --workflow CI --status success --limit 1 --json databaseId --jq '.[0].databaseId')}
[[ -n $run ]] || { echo "fetch-agent-msi: no successful CI run on main" >&2; exit 1; }
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
gh run download "$run" --name vmpane-agent-windows-arm64 --dir "$tmp"
msi=$(find "$tmp" -name 'vmpane-agent.msi' | head -1)
[[ -n $msi ]] || { echo "fetch-agent-msi: run $run has no MSI" >&2; exit 1; }
mkdir -p "$out"
cp "$msi" "$out/vmpane-agent.msi"
echo "$out/vmpane-agent.msi (CI run $run)"
