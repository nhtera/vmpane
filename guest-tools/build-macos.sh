#!/usr/bin/env bash
# Stages the macOS guest tools: "VMPane Agent.pkg" (the agent binary, its LaunchDaemon, the session helper's
# LaunchAgent) and SHA256SUMS, in build/guest-tools/macos/ (the app embeds it as Contents/Resources/GuestTools/macos;
# macOS guests see it as /Volumes/My Shared Files/vmpane-tools).
# Signing: the binary with $VMPANE_SIGN_IDENTITY (default "-", ad hoc; hardened runtime for real identities) and the
# package with $VMPANE_INSTALLER_IDENTITY (a "Developer ID Installer" identity) when set; VMPANE_NOTARIZE=1 then
# notarizes and staples it (scripts/notarize.sh). Prints the directory.
# Usage: guest-tools/build-macos.sh
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
out="$root/build/guest-tools/macos"
installer="$root/agent/installer/macos"
identity=${VMPANE_SIGN_IDENTITY:--}
version=$(sed -n 's/^version = "\(.*\)"$/\1/p' "$root/agent/Cargo.toml" | head -1)

(cd "$root/agent" && cargo build --release --locked --quiet --target aarch64-apple-darwin -p vmpane-agent)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
payload="$work/payload"
install -d "$payload/Library/Application Support/VMPane/Agent" "$payload/Library/LaunchDaemons" "$payload/Library/LaunchAgents"
binary="$payload/Library/Application Support/VMPane/Agent/vmpane-agent"
install -m 0755 "$root/agent/target/aarch64-apple-darwin/release/vmpane-agent" "$binary"
install -m 0644 "$installer/app.vmpane.agent.plist" "$payload/Library/LaunchDaemons/"
install -m 0644 "$installer/app.vmpane.session.plist" "$payload/Library/LaunchAgents/"
if [[ $identity == - ]]; then
    codesign --force --sign - --identifier app.vmpane.agent "$binary" 2>/dev/null
else
    codesign --force --sign "$identity" --identifier app.vmpane.agent --options runtime --timestamp "$binary"
fi

# Extended attributes travel as ._ entries (Installer restores them as attributes); the provenance attribute
# macOS puts on every new file cannot be cleared, the rest is.
xattr -cr "$payload"
COPYFILE_DISABLE=1 pkgbuild --quiet --root "$payload" --scripts "$installer/scripts" --identifier app.vmpane.agent --version "$version" \
    --install-location / "$work/vmpane-agent-component.pkg"
productbuild --quiet --distribution "$installer/distribution.xml" --package-path "$work" "$work/unsigned.pkg"
pkg="$work/VMPane Agent.pkg"
if [[ -n ${VMPANE_INSTALLER_IDENTITY:-} ]]; then
    productsign --sign "$VMPANE_INSTALLER_IDENTITY" --timestamp "$work/unsigned.pkg" "$pkg" >/dev/null
    if [[ ${VMPANE_NOTARIZE:-} == 1 ]]; then
        "$root/scripts/notarize.sh" "$pkg"
    fi
else
    mv "$work/unsigned.pkg" "$pkg"
fi

rm -rf "$out.partial"
mkdir -p "$out.partial"
cp "$pkg" "$out.partial/"
(cd "$out.partial" && shasum -a 256 "VMPane Agent.pkg" >SHA256SUMS)
rm -rf "$out"
mv "$out.partial" "$out"
echo "$out"
