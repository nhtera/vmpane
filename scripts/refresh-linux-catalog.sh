#!/usr/bin/env bash
# Pins the Linux cloud images in VMPane's catalog (Packages/VMPaneKit/Sources/VMPaneHost/Install/Resources/
# linux-catalog.json): release tooling, and the catalog's trust root (scripts/ and the catalog are CODEOWNERS-guarded).
# The app checks each download against the SHA-256 pinned here; this script decides what gets pinned:
#   Ubuntu  SHA256SUMS, signed by Ubuntu's cloud image key (detached signature)
#   Fedora  CHECKSUM, clearsigned by the release's key: hashes are read only from gpg's verified output
#   Debian  its cloud images are not signed: SHA512SUMS over HTTPS, the image downloaded and checked against it,
#           its SHA-256 computed here
# Signing keys are fetched, but a signature counts only when gpg reports the fingerprint pinned below (VALIDSIG).
# Anything unexpected fails the run and leaves the catalog as it was.
# Usage: scripts/refresh-linux-catalog.sh <ubuntu build> <debian build> <fedora release> <fedora compose>
#   e.g. scripts/refresh-linux-catalog.sh 20261016 20261021-2638 44 1.7
set -euo pipefail
(($# == 4)) || { sed -n '2,13p' "$0" >&2; exit 2; }
ubuntu_build=$1 debian_build=$2 fedora_release=$3 fedora_compose=$4
root=$(cd "$(dirname "$0")/.." && pwd)
catalog="$root/Packages/VMPaneKit/Sources/VMPaneHost/Install/Resources/linux-catalog.json"

# Key fingerprints, pinned (check each against the distribution's own published value when it changes).
ubuntu_key=D2EB44626FDDC30B513D5BB71A5D6C4C7DB87C81    # UEC Image Automatic Signing Key <cdimage@ubuntu.com>
fedora_keys=(36F612DCF27F7D1A48A835E4DBFCF71C6D9F90A6)  # Fedora (44) <fedora-44-primary@fedoraproject.org>

work=$(mktemp -d)
trap 'gpgconf --kill all 2>/dev/null; rm -rf "$work"' EXIT
export GNUPGHOME="$work/gnupg"
mkdir -m 0700 "$GNUPGHOME"
fetch() { curl -fsSL --proto '=https' --tlsv1.2 --retry 3 -o "$2" "$1"; }

# Exits unless gpg succeeded ($3, its exit code) and its status output ($1) has exactly one good signature, by
# pinned fingerprint $2, and no bad or unverifiable one.
signed_by() {
    (($3 == 0)) && ! grep -qE "^\[GNUPG:\] (BADSIG|ERRSIG|EXPKEYSIG|REVKEYSIG) " "$1" \
        && [[ $(grep -c "^\[GNUPG:\] VALIDSIG " "$1") == 1 ]] \
        && awk -v want="$2" '$2 == "VALIDSIG" && ($3 == want || $NF == want) {ok = 1} END {exit !ok}' "$1" \
        || { echo "refresh-linux-catalog: no good signature by $2" >&2; cat "$1" >&2; exit 1; }
}

# --- Ubuntu
ubuntu_version=26.04
ubuntu_dir="https://cloud-images.ubuntu.com/releases/$ubuntu_version/release-$ubuntu_build"
ubuntu_file="ubuntu-$ubuntu_version-server-cloudimg-arm64.img"
gpg --batch --quiet --keyserver hkps://keyserver.ubuntu.com --recv-keys "$ubuntu_key"
fetch "$ubuntu_dir/SHA256SUMS" "$work/ubuntu.sums"
fetch "$ubuntu_dir/SHA256SUMS.gpg" "$work/ubuntu.sig"
status=0
gpg --batch --status-fd 3 --verify "$work/ubuntu.sig" "$work/ubuntu.sums" 3>"$work/ubuntu.status" 2>/dev/null || status=$?
signed_by "$work/ubuntu.status" "$ubuntu_key" "$status"
ubuntu_sha=$(awk -v f="*$ubuntu_file" '$2 == f {print $1}' "$work/ubuntu.sums")

# --- Fedora
fedora_dir="https://download.fedoraproject.org/pub/fedora/linux/releases/$fedora_release/Cloud/aarch64/images"
fedora_file="Fedora-Cloud-Base-Generic-$fedora_release-$fedora_compose.aarch64.qcow2"
fetch https://fedoraproject.org/fedora.gpg "$work/fedora.gpg"
gpg --batch --quiet --import "$work/fedora.gpg"
fetch "$fedora_dir/Fedora-Cloud-$fedora_release-$fedora_compose-aarch64-CHECKSUM" "$work/fedora.checksum"
status=0
gpg --batch --status-fd 3 --output "$work/fedora.verified" --decrypt "$work/fedora.checksum" 3>"$work/fedora.status" 2>/dev/null \
    || status=$?
signed_by "$work/fedora.status" "${fedora_keys[0]}" "$status"
fedora_sha=$(sed -nE "s/^SHA256 \\($fedora_file\\) = ([0-9a-f]{64})$/\\1/p" "$work/fedora.verified")

# --- Debian
debian_dir="https://cloud.debian.org/images/cloud/trixie/$debian_build"
# `generic`, not `genericcloud`: the cloud kernel has no display (no DRM), so no screen to see or read.
debian_file="debian-13-generic-arm64-$debian_build.qcow2"
fetch "$debian_dir/SHA512SUMS" "$work/debian.sums"
debian_sha512=$(awk -v f="$debian_file" '$2 == f {print $1}' "$work/debian.sums")
[[ $debian_sha512 =~ ^[0-9a-f]{128}$ ]] || { echo "refresh-linux-catalog: no SHA-512 for $debian_file" >&2; exit 1; }
fetch "$debian_dir/$debian_file" "$work/debian.qcow2"
[[ $(shasum -a 512 "$work/debian.qcow2" | cut -d' ' -f1) == "$debian_sha512" ]] \
    || { echo "refresh-linux-catalog: $debian_file does not match SHA512SUMS" >&2; exit 1; }
debian_sha=$(shasum -a 256 "$work/debian.qcow2" | cut -d' ' -f1)
debian_size=$(stat -f %z "$work/debian.qcow2")

for sha in "$ubuntu_sha" "$fedora_sha" "$debian_sha"; do
    [[ $sha =~ ^[0-9a-f]{64}$ ]] || { echo "refresh-linux-catalog: a SHA-256 is missing" >&2; exit 1; }
done
size() { curl -fsSLI --proto '=https' "$1" | awk 'tolower($1) == "content-length:" {n = $2} END {gsub("\r", "", n); print n}'; }
ubuntu_size=$(size "$ubuntu_dir/$ubuntu_file")
fedora_size=$(size "$fedora_dir/$fedora_file")
for n in "$ubuntu_size" "$fedora_size"; do [[ $n =~ ^[0-9]+$ ]] || { echo "refresh-linux-catalog: no size" >&2; exit 1; }; done

jq --indent 2 \
    --arg uu "$ubuntu_dir/$ubuntu_file" --arg us "$ubuntu_sha" --argjson un "$ubuntu_size" --arg ub "$ubuntu_build" \
    --arg du "$debian_dir/$debian_file" --arg ds "$debian_sha" --argjson dn "$debian_size" --arg db "$debian_build" \
    --arg fu "$fedora_dir/$fedora_file" --arg fs "$fedora_sha" --argjson fn "$fedora_size" --arg fr "$fedora_release" \
    --arg fc "$fedora_compose" \
    '.images = [.images[] | select(.kind != "cloudImage")] + [
        {id: "ubuntu-26.04-cloud", name: "Ubuntu 26.04 LTS", version: "26.04", build: $ub, kind: "cloudImage",
         distro: "ubuntu", url: $uu, sha256: $us, sizeBytes: $un},
        {id: "debian-13-cloud", name: "Debian 13", version: "13", build: $db, kind: "cloudImage", distro: "debian",
         url: $du, sha256: $ds, sizeBytes: $dn},
        {id: ("fedora-" + $fr + "-cloud"), name: ("Fedora " + $fr), version: $fr, build: $fc, kind: "cloudImage",
         distro: "fedora", url: $fu, sha256: $fs, sizeBytes: $fn}
    ]' "$catalog" >"$work/catalog.json"
mv "$work/catalog.json" "$catalog"
echo "refresh-linux-catalog: pinned Ubuntu $ubuntu_build, Debian $debian_build, Fedora $fedora_release-$fedora_compose"
