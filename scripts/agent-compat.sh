#!/usr/bin/env bash
# Agent protocol compatibility across releases (Phase 07, before each release):
#   1. the agents of the two previous release tags (N-1, N-2) and of the floor tag ($VMPANE_AGENT_FLOOR_TAG, the
#      first release speaking proto 1) against this host: the Swift tests that run a real agent, with
#      VMPANE_AGENT_BINARY pointing at each release's macOS agent;
#   2. this agent against the previous release's host: the same tests in a worktree of N-1.
# Agents come from the releases' assets (vmpane-agent-macos-arm64-<tag>.tar.gz). Without earlier releases there is
# nothing to check, and the script says so.
# Usage: scripts/agent-compat.sh
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
filter='realAgent|helperRuns|helperPushes'
tags=()
while IFS= read -r tag; do tags+=("$tag"); done < <(git -C "$root" tag --list 'v*' --sort=-v:refname | head -2)
[[ -n ${VMPANE_AGENT_FLOOR_TAG:-} ]] && tags+=("$VMPANE_AGENT_FLOOR_TAG")
if ((${#tags[@]} == 0)); then
    echo "agent-compat: no earlier releases yet; nothing to check"
    exit 0
fi
work=$(mktemp -d)
trap 'git -C "$root" worktree remove --force "$work/host" 2>/dev/null || true; rm -rf "$work"' EXIT

for tag in "${tags[@]}"; do
    echo "== agent $tag against this host"
    gh release download "$tag" --repo nhtera/vmpane --pattern "vmpane-agent-macos-arm64-$tag.tar.gz" --dir "$work/$tag"
    tar -xzf "$work/$tag/vmpane-agent-macos-arm64-$tag.tar.gz" -C "$work/$tag"
    VMPANE_AGENT_BINARY="$work/$tag/vmpane-agent-macos-arm64" "$root/scripts/test.sh" --swift-only --filter "$filter"
done

previous=${tags[0]}
echo "== this agent against the $previous host"
(cd "$root/agent" && cargo build --quiet -p vmpane-agent)
git -C "$root" worktree add --detach "$work/host" "$previous" >/dev/null
VMPANE_AGENT_BINARY="$root/agent/target/debug/vmpane-agent" "$work/host/scripts/test.sh" --swift-only --filter "$filter"
echo "agent-compat: all compatible"
