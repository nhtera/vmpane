#!/usr/bin/env bash
# Build VMPane.app with Xcode and sign it from the manifest. Output: build/<Configuration>/VMPane.app.
# Signs with $VMPANE_SIGN_IDENTITY (default ad hoc): Xcode's own signature is development-only.
# Usage: scripts/build.sh [Debug|Release]
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib/env.sh

config=${1:-Debug}
case "$config" in Debug|Release) ;; *) echo "usage: scripts/build.sh [Debug|Release]" >&2; exit 2 ;; esac

xcodegen generate --quiet
# ARCHS on the command line applies to Swift package targets too (they ignore the project's xcconfig):
# VMPane is Apple-silicon only, and some Virtualization APIs (Rosetta) do not exist for x86_64.
xcodebuild -project VMPane.xcodeproj -scheme VMPane -configuration "$config" \
    -derivedDataPath build/dd -destination 'platform=macOS,arch=arm64' ARCHS=arm64 ONLY_ACTIVE_ARCH=NO -quiet build

rm -rf "build/$config/VMPane.app"
mkdir -p "build/$config"
ditto "build/dd/Build/Products/$config/VMPane.app" "build/$config/VMPane.app"
scripts/sign.sh "build/$config/VMPane.app" >/dev/null
echo "build: build/$config/VMPane.app"
