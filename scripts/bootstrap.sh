#!/usr/bin/env bash
# Set up a development Mac: Homebrew tools, Xcode check, pinned tools, Rust toolchain, cargo tools,
# Xcode project.
set -euo pipefail
cd "$(dirname "$0")/.."

brew bundle --file Brewfile
source scripts/lib/env.sh

want=$(tr -d '[:space:]' < .xcode-version)
have=$(xcodebuild -version | awk 'NR==1 {print $2}')
if [[ "$have" != "$want" ]]; then
    echo "error: Xcode $want required (found $have); see .xcode-version" >&2
    exit 1
fi

# In agent/ so rustup and cargo use the toolchain pinned in agent/rust-toolchain.toml.
cd agent
rustup toolchain install
installed=$(cargo install --list)
grep -v '^#' ../scripts/cargo-tools.txt | while read -r name version flags; do
    [[ -n "$name" ]] || continue
    if ! grep -q "^$name v$version:" <<<"$installed"; then
        # shellcheck disable=SC2086 # flags is a word list on purpose
        cargo install --locked "$name" --version "$version" $flags
    fi
done
cd ..

xcodegen generate --quiet
echo "bootstrap: ok"
