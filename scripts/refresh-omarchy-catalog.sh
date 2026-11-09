#!/usr/bin/env bash
# Pins Omarchy's arm64 ISO in VMPane's Linux catalog (Packages/VMPaneKit/Sources/VMPaneHost/Install/Resources/
# linux-catalog.json): release tooling, and the catalog's trust root, like scripts/refresh-linux-catalog.sh.
# Omarchy signs the ISO itself (a detached signature beside it, by its release key), not a checksum list: the ISO is
# downloaded (5.7 GB), the signature checked, and its SHA-256 computed here. A signature counts only when gpg reports
# the fingerprint pinned below (VALIDSIG). Anything unexpected fails the run and leaves the catalog as it was.
# Usage: scripts/refresh-omarchy-catalog.sh <version> [<downloaded ISO>]
#   e.g. scripts/refresh-omarchy-catalog.sh 4.5.0
#   A second argument reuses an ISO downloaded before (its name must be the release's), skipping the download.
set -euo pipefail
(($# == 1 || $# == 2)) || { sed -n '2,9p' "$0" >&2; exit 2; }
version=$1
root=$(cd "$(dirname "$0")/.." && pwd)
catalog="$root/Packages/VMPaneKit/Sources/VMPaneHost/Install/Resources/linux-catalog.json"

# Omarchy's release key, pinned (Omarchy <pkgs@omarchy.org>; check against omarchy.org when it changes).
omarchy_key=40DFB630FF42BCFFB047046CF0134EE680CAC571

iso_name="omarchy-$version-aarch64.iso"
iso_url="https://iso.omarchy.org/$iso_name"
work=$(mktemp -d)
trap 'gpgconf --kill all 2>/dev/null; rm -rf "$work"' EXIT
export GNUPGHOME="$work/gnupg"
mkdir -m 0700 "$GNUPGHOME"
fetch() { curl -fsSL --proto '=https' --tlsv1.2 --retry 3 -o "$2" "$1"; }

if (($# == 2)); then
    iso=$2
    [[ $(basename "$iso") == "$iso_name" ]] || { echo "refresh-omarchy-catalog: $iso is not $iso_name" >&2; exit 1; }
else
    iso="$work/$iso_name"
    echo "refresh-omarchy-catalog: downloading $iso_url (about 6 GB)" >&2
    curl -fL --proto '=https' --tlsv1.2 --retry 3 -o "$iso" "$iso_url"
fi
fetch "$iso_url.sig" "$work/iso.sig"
gpg --batch --quiet --keyserver hkps://keys.openpgp.org --recv-keys "$omarchy_key"
status=0
gpg --batch --status-fd 3 --verify "$work/iso.sig" "$iso" 3>"$work/iso.status" 2>/dev/null || status=$?
(($status == 0)) && ! grep -qE "^\[GNUPG:\] (BADSIG|ERRSIG|EXPKEYSIG|REVKEYSIG) " "$work/iso.status" \
    && [[ $(grep -c "^\[GNUPG:\] VALIDSIG " "$work/iso.status") == 1 ]] \
    && awk -v want="$omarchy_key" '$2 == "VALIDSIG" && ($3 == want || $NF == want) {ok = 1} END {exit !ok}' "$work/iso.status" \
    || { echo "refresh-omarchy-catalog: no good signature by $omarchy_key" >&2; cat "$work/iso.status" >&2; exit 1; }

sha=$(shasum -a 256 "$iso" | cut -d' ' -f1)
[[ $sha =~ ^[0-9a-f]{64}$ ]] || { echo "refresh-omarchy-catalog: no SHA-256" >&2; exit 1; }
# Omarchy's own checksum file must agree (a download that passed the signature but not this is a bug here).
fetch "$iso_url.sha256" "$work/iso.sha256"
[[ $(cut -d' ' -f1 "$work/iso.sha256") == "$sha" ]] || { echo "refresh-omarchy-catalog: $iso_name does not match its .sha256" >&2; exit 1; }
size=$(stat -f %z "$iso")

jq --indent 2 --arg id "omarchy-$version" --arg v "$version" --arg u "$iso_url" --arg s "$sha" --argjson n "$size" \
    '.images = [.images[] | select(.distro != "omarchy")] + [
        {id: $id, name: "Omarchy", version: $v, kind: "autoinstallISO", distro: "omarchy", url: $u, sha256: $s, sizeBytes: $n}
    ]' "$catalog" >"$work/catalog.json"
mv "$work/catalog.json" "$catalog"
echo "refresh-omarchy-catalog: pinned Omarchy $version ($sha)"
