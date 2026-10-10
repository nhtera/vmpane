#!/usr/bin/env bash
# The corresponding source of the QEMU bundle (GPL/LGPL), published as a release asset next to each DMG:
#   qemu/        deps.lock, patches, device allowlist, build and packaging scripts, licences, BUILDING.md
#   scripts/, Config/   the scripts and settings that sign and check the bundle when it goes into the app
#   downloads/   the source tarball of every shipped component and of the tools built from source
#   firmware/    the exact EDK2 source the firmware was built from (with submodules), and the dbx update
#   SHA256SUMS
# The Python interpreter and wheels used for the build are binaries; deps.lock and tools-requirements.txt
# pin them by URL and hash.
#
# Usage: qemu/scripts/source-bundle.sh --out <file.tar.zst>
#        qemu/scripts/source-bundle.sh --verify <file.tar.zst>
#   --verify  extracts into a temporary directory, checks every file against SHA256SUMS and every component
#             in the bundled deps.lock against its pinned SHA-256, and that each listed patch is present.
set -euo pipefail
source "$(dirname "$0")/lib/env.sh"

top=vmpane-qemu-source
# Tools built from source are part of the build; the Python runtime is a binary download.
included() { jq -r '.components[] | select(.role == "runtime" or .name != "python") | .name' "$1"; }

verify() {
    local archive=$1 dir lock name file failures=0
    [[ -f $archive ]] || die "no $archive"
    dir=$(mktemp -d)
    trap 'rm -rf "$dir"' RETURN
    tar --zstd -xf "$archive" -C "$dir"
    cd "$dir/$top"
    shasum -a 256 -c --quiet SHA256SUMS || die "SHA256SUMS mismatch in $archive"
    lock=qemu/deps.lock
    for name in $(included "$lock"); do
        file=$(find downloads -name "$name-$(jq -r --arg n "$name" '.components[] | select(.name == $n) | .version' "$lock").*" | head -1)
        if [[ -z $file ]]; then
            echo "missing source: $name" >&2
            failures=$((failures + 1))
        elif [[ $(shasum -a 256 "$file" | cut -d' ' -f1) != $(jq -r --arg n "$name" '.components[] | select(.name == $n) | .sha256' "$lock") ]]; then
            echo "SHA-256 differs from deps.lock: $file" >&2
            failures=$((failures + 1))
        fi
        for patch in $(jq -r --arg n "$name" '.components[] | select(.name == $n) | .patches[]' "$lock"); do
            [[ -f qemu/patches/$name/$patch ]] || { echo "missing patch: $name/$patch" >&2; failures=$((failures + 1)); }
        done
    done
    [[ -f firmware/edk2-src.tar.gz ]] || { echo "missing firmware/edk2-src.tar.gz" >&2; failures=$((failures + 1)); }
    ((failures == 0)) || die "$failures problem(s) in $archive"
    echo "source-bundle: $archive verified ($(wc -l <SHA256SUMS | tr -d ' ') files)"
}

case ${1:-} in
    --verify)
        verify "$(cd "$(dirname "${2:?--verify needs a file}")" && pwd)/$(basename "$2")"
        exit 0
        ;;
    --out) out=${2:?--out needs a file} ;;
    *) die "usage: source-bundle.sh --out <file.tar.zst> | --verify <file.tar.zst>" ;;
esac
[[ -f $BUILD/firmware/edk2-src.tar.gz ]] || die "no EDK2 source; run qemu/scripts/build-edk2.sh"

stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
root=$stage/$top
mkdir -p "$root/downloads" "$root/firmware" "$root/scripts" "$root/Config/Entitlements"
# The tracked files of qemu/ (never the build directory).
(cd "$REPO_DIR" && git ls-files -z qemu | tar --null -T - -cf -) | tar -xf - -C "$root"
cp "$REPO_DIR/scripts/sign.sh" "$REPO_DIR/scripts/check-dylibs.sh" "$root/scripts/"
cp "$REPO_DIR/Config/signing-manifest.json" "$root/Config/"
cp "$REPO_DIR/Config/Entitlements/qemu.entitlements" "$root/Config/Entitlements/"
for name in $(included "$LOCK"); do cp "$(fetch "$name")" "$root/downloads/"; done
cp "$BUILD/firmware/edk2-src.tar.gz" "$(fetch_firmware dbx)" "$root/firmware/"
(cd "$root" && find . -type f ! -name SHA256SUMS | sed 's|^\./||' | LC_ALL=C sort | xargs shasum -a 256 >SHA256SUMS)

mkdir -p "$(dirname "$out")"
tar --zstd -cf "$out" -C "$stage" "$top"
echo "source-bundle: $out ($(du -h "$out" | cut -f1))"
