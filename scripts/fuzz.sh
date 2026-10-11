#!/usr/bin/env bash
# Fuzz smoke: each cargo-fuzz target of the agent protocol for $1 seconds (default 300), then the Swift
# decoders' seeded mutation test with a million iterations. Needs the nightly toolchain and cargo-fuzz.
# Usage: scripts/fuzz.sh [seconds]
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
seconds=${1:-300}
cd "$root/agent/fuzz"
for target in frame_decode jsonrpc_parse; do
    echo "== fuzz $target (${seconds} s)"
    cargo +nightly fuzz run "$target" -- -max_total_time="$seconds" -max_len=1100000
done
echo "== Swift decoder mutations (1M)"
cd "$root"
VMPANE_FUZZ_ITERATIONS=1000000 scripts/test.sh --swift-only --release --filter RandomizedDecoder
