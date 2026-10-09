#!/usr/bin/env bash
# Notarize and staple a signed .dmg (or notarize a .zip of the app), then check Gatekeeper.
# Credentials: notarytool keychain profile $VMPANE_NOTARY_PROFILE (default vmpane-notary), created with
#   xcrun notarytool store-credentials vmpane-notary --apple-id <id> --team-id <team>
# Usage: scripts/notarize.sh <file.dmg|file.zip> [<VMPane.app to staple when submitting a zip>]
set -euo pipefail

file=${1:?usage: scripts/notarize.sh <file.dmg|file.zip> [VMPane.app]}
profile=${VMPANE_NOTARY_PROFILE:-vmpane-notary}

# Parse the result even when notarytool exits non-zero, so the log can still be fetched.
rc=0
result=$(xcrun notarytool submit "$file" --keychain-profile "$profile" --wait --output-format json) || rc=$?
status=$(jq -r '.status // "unknown"' <<<"$result" 2>/dev/null || echo unknown)
id=$(jq -r '.id // empty' <<<"$result" 2>/dev/null || true)
echo "notarization $id: $status"
if [[ "$status" != Accepted || $rc != 0 ]]; then
    [[ -n "$id" ]] && { xcrun notarytool log "$id" --keychain-profile "$profile" >&2 || true; }
    exit 1
fi

case "$file" in
    *.dmg)
        xcrun stapler staple "$file"
        spctl -a -vv -t open --context context:primary-signature "$file"
        ;;
    *.zip)
        # A zip cannot be stapled; staple the app it was made from.
        if [[ -n "${2:-}" ]]; then
            xcrun stapler staple "$2"
            spctl -a -vv "$2"
        fi
        ;;
esac
