#!/usr/bin/env bash
# Builds the Windows guest-tools ISO (volume VMPANE_TOOLS) from guest-tools/tools.lock:
#   1. the pinned virtio-win ISO, downloaded once into the cache and checked against its SHA-256;
#   2. for each driver that passed Gate 00 S2, its ARM64 w11 directory (without debug symbols), after checking
#      that its catalog is signed by the Windows Hardware Compatibility Publisher, chained to the Microsoft root
#      pinned in trust/ (its fingerprint is in the lock), and that every PE file (.sys, .exe, .dll) is listed in
#      that catalog or carries its own signature by the same publisher (Balloon's blnsvr.exe); the lock's
#      `exclude` list names the files left out (test-signed utilities no INF installs). INF files are
#      covered by the ISO's SHA-256 and checked by Windows itself at install;
#   3. windows/install.ps1 and README.txt at the root (the unattend runs <VMPANE_TOOLS>:\install.ps1), the
#      licences under LICENSES/ (from the sources themselves), and any extra installers in
#      $VMPANE_GUEST_TOOLS_EXTRA (Phase 07: the agent MSI);
#   4. hdiutil makehybrid → build/guest-tools/vmpane-guest-tools-windows-<version>.iso.
# Needs jq, osslsigncode and openssl. VMPANE_GUEST_TOOLS_DOWNLOADS overrides the download cache.
# Usage: guest-tools/build-iso.sh [output.iso]
set -euo pipefail

DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(dirname "$DIR")
LOCK=$DIR/tools.lock
BUILD=$REPO_DIR/build/guest-tools
DOWNLOADS=${VMPANE_GUEST_TOOLS_DOWNLOADS:-$BUILD/downloads}
STAGE=$BUILD/stage
version=$(jq -er .version "$LOCK")
label=$(jq -er .volumeLabel "$LOCK")
output=${1:-$BUILD/vmpane-guest-tools-windows-$version.iso}

die() {
    echo "error: $*" >&2
    exit 1
}

for tool in jq osslsigncode openssl hdiutil; do
    command -v "$tool" >/dev/null || die "$tool is required"
done

# The pinned root: the committed certificate must be the one the lock names.
root=$DIR/$(jq -er .trust.file "$LOCK")
signer=$(jq -er .trust.signer "$LOCK")
fingerprint=$(openssl x509 -in "$root" -noout -fingerprint -sha256 | cut -d= -f2 | tr -d : | tr '[:upper:]' '[:lower:]')
[[ $fingerprint == "$(jq -er .trust.sha256 "$LOCK")" ]] || die "$root does not match the fingerprint in tools.lock"

# 1. virtio-win
url=$(jq -er .virtioWin.url "$LOCK")
sha=$(jq -er .virtioWin.sha256 "$LOCK")
iso=$DOWNLOADS/$(basename "$url")
mkdir -p "$DOWNLOADS"
if [[ ! -f $iso ]]; then
    rm -f "$iso.partial"
    curl -fsSL --retry 3 -o "$iso.partial" "$url" || die "download failed: $url"
    mv "$iso.partial" "$iso"
fi
if [[ $(shasum -a 256 "$iso" | cut -d' ' -f1) != "$sha" ]]; then
    rm -f "$iso"
    die "SHA-256 mismatch (file removed): $url"
fi

mount=$(mktemp -d "${TMPDIR:-/tmp}/vmpane-virtio-win.XXXXXX")
cleanup() {
    hdiutil detach -quiet "$mount" 2>/dev/null || true
    rmdir "$mount" 2>/dev/null || true
}
trap cleanup EXIT
hdiutil attach -readonly -nobrowse -noautoopen -mountpoint "$mount" "$iso" >/dev/null

# verify <file>: its own Authenticode signature (a catalog's, or a PE file's) chains to the pinned root only
# (the timestamp too) and was made by the pinned publisher.
verify() {
    local result
    result=$(osslsigncode verify -CAfile "$root" -TSA-CAfile "$root" -in "$1" 2>&1) ||
        die "signature check failed: ${1#"$mount"/}"
    # The first subject after "Signer's certificate:" is the leaf that signed the file.
    [[ $(awk '/^Signer.s certificate:/ { found = 1 } found && /Subject:/ { sub(/^[ \t]*Subject: /, ""); print; exit }' <<<"$result") == "$signer" ]] ||
        die "unexpected signer: ${1#"$mount"/}"
}

# 2. Drivers
rm -rf "$STAGE"
mkdir -p "$STAGE/drivers" "$STAGE/LICENSES"
driver_path=$(jq -er .virtioWin.driverPath "$LOCK")
while IFS= read -r driver; do
    source=$mount/$driver/$driver_path
    [[ -d $source ]] || die "virtio-win has no $driver/$driver_path"
    catalogs=("$source"/*.cat)
    [[ -f ${catalogs[0]} ]] || die "$driver: no catalog"
    for catalog in "${catalogs[@]}"; do verify "$catalog"; done
    mkdir -p "$STAGE/drivers/$driver"
    for file in "$source"/*; do
        name=$(basename "$file")
        jq -e --arg f "$driver/$name" '.virtioWin.exclude | index($f)' "$LOCK" >/dev/null && continue
        case $name in
        *.pdb) continue ;;
        *.sys | *.exe | *.dll)
            listed=false
            for catalog in "${catalogs[@]}"; do
                if osslsigncode verify -CAfile "$root" -TSA-CAfile "$root" -catalog "$catalog" -in "$file" >/dev/null 2>&1; then
                    listed=true
                    break
                fi
            done
            $listed || verify "$file"
            ;;
        esac
        cp "$file" "$STAGE/drivers/$driver/"
    done
    echo "driver $driver: verified"
done < <(jq -r '.virtioWin.drivers[]' "$LOCK")
cp "$mount/$(jq -er .virtioWin.licenseFile "$LOCK")" "$STAGE/LICENSES/virtio-win.txt"

# 3. Scripts, notes, extra installers
cp "$DIR/windows/install.ps1" "$DIR/windows/README.txt" "$STAGE/"
if [[ -n ${VMPANE_GUEST_TOOLS_EXTRA:-} ]]; then
    for extra in "$VMPANE_GUEST_TOOLS_EXTRA"/*.msi; do
        [[ -f $extra ]] && cp "$extra" "$STAGE/"
    done
fi
echo "$version" >"$STAGE/VERSION.txt"
chmod -R a+rX,go-w "$STAGE"

# 4. The ISO (hdiutil appends .iso to a name without it, so the partial keeps the extension)
mkdir -p "$(dirname "$output")"
partial=${output%.iso}.partial.iso
rm -f "$partial"
hdiutil makehybrid -quiet -iso -joliet -default-volume-name "$label" -o "$partial" "$STAGE"
mv "$partial" "$output"
echo "$output"
