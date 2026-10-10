#!/usr/bin/env bash
# Unit tests: the Swift package (fails on any compiler warning or when zero tests ran), then the Rust agent.
# Usage: scripts/test.sh [--filter <regex>] [--swift-only] [--release] [--asan]
#   --release  Swift tests in the release configuration (optimizer-only bugs)
#   --asan     Swift tests with the address sanitizer
# Set VMPANE_XWIN=1 to also cross-build the Windows agent with cargo-xwin (downloads the MSVC CRT
# and Windows SDK, which accepts Microsoft's licence terms); CI builds it on windows-11-arm.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib/env.sh

filter=()
# Any compiler warning fails the run, strict-concurrency diagnostics included (Swift 6 language mode).
swift_flags=(-Xswiftc -warnings-as-errors)
swift_only=0
while (($#)); do
    case "$1" in
        --filter) filter=(--filter "$2"); shift 2 ;;
        --swift-only) swift_only=1; shift ;;
        --release) swift_flags+=(-c release); shift ;;
        --asan) swift_flags+=(--sanitize=address); shift ;;
        *) echo "usage: scripts/test.sh [--filter <regex>] [--swift-only] [--release] [--asan]" >&2; exit 2 ;;
    esac
done

log=$(mktemp)
trap 'rm -f "$log"' EXIT
swift test --package-path Packages/VMPaneKit ${swift_flags[@]+"${swift_flags[@]}"} ${filter[@]+"${filter[@]}"} 2>&1 | tee "$log"

# Swift Testing prints "Test run with N tests", XCTest "Executed N tests"; the last line is the total.
st=$(sed -nE 's/.*Test run with ([0-9]+) tests?.*/\1/p' "$log" | tail -1)
xc=$(sed -nE 's/.*Executed ([0-9]+) tests?.*/\1/p' "$log" | tail -1)
total=$(( ${st:-0} + ${xc:-0} ))
if (( total == 0 )); then
    echo "error: no Swift tests ran (filter: ${filter[*]:-none})" >&2
    exit 1
fi
echo "swift: $total tests"

if (( swift_only )); then
    exit 0
fi

cd agent
cargo test --workspace
cargo deny check
cargo build --release --target aarch64-apple-darwin
cargo build --release --target aarch64-unknown-linux-musl
if [[ "${VMPANE_XWIN:-0}" == 1 ]]; then
    cargo xwin build --release --target aarch64-pc-windows-msvc
fi
echo "test: ok"
