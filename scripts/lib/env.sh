# Sourced by the scripts in scripts/: puts the pinned tools and the Rust toolchain on PATH.
# Homebrew's rustup is keg-only (not linked); rustup.rs installs into ~/.cargo/bin.
VMPANE_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
export PATH="$VMPANE_ROOT/build/tools/bin:$HOME/.cargo/bin:/opt/homebrew/opt/rustup/bin:$PATH"
"$VMPANE_ROOT/scripts/install-tools.sh"
