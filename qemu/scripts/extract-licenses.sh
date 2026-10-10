#!/usr/bin/env bash
# Copies the licence texts of everything VMPane ships from the QEMU pipeline into qemu/LICENSES/<component>/,
# from the pinned tarballs (and the EDK2 source build-edk2.sh wrote). The files are committed:
# scripts/gen-notices.sh puts them in THIRD_PARTY_NOTICES.md, and CI checks the notices without downloading
# any source. Run after changing a runtime component or the firmware in deps.lock.
# Usage: qemu/scripts/extract-licenses.sh
set -euo pipefail
source "$(dirname "$0")/lib/env.sh"

licenses=$QEMU_DIR/LICENSES
# Top-level files that hold licence terms (libjpeg-turbo keeps the IJG terms in README.ijg, dtc in
# README.license with the texts in BSD-2-Clause and GPL).
pattern='^(COPYING|COPYING\.LIB|LICEN[CS]E|LICEN[CS]E\.(md|txt)|README\.ijg|README\.license|BSD-2-Clause|GPL)$'
# EDK2 and the bundled projects ArmVirtQemu builds from (paths inside its source tarball).
edk2_files=(License.txt ArmPkg/Library/ArmSoftFloatLib/berkeley-softfloat-3/COPYING.txt
    CryptoPkg/Library/OpensslLib/openssl/LICENSE.txt MdeModulePkg/Library/BrotliCustomDecompressLib/brotli/LICENSE
    MdeModulePkg/Universal/RegularExpressionDxe/oniguruma/COPYING)

# Keep only the directories of what is shipped now (UTM's licence covers patches, not a component).
find "$licenses" -mindepth 1 -maxdepth 1 -type d ! -name UTM -exec rm -rf {} +

for name in $(lock_names runtime); do
    tarball=$(fetch "$name")
    top=$(tar -tf "$tarball" | head -1 | cut -d/ -f1)
    files=$(tar -tf "$tarball" | awk -F/ -v top="$top" -v re="$pattern" '$1 == top && NF == 2 && $2 ~ re {print $2}')
    [[ -n $files ]] || die "$name: no licence file at the top of $(basename "$tarball")"
    mkdir -p "$licenses/$name"
    for f in $files; do tar -xOf "$tarball" "$top/$f" >"$licenses/$name/$f"; done
done

edk2_src=$BUILD/firmware/edk2-src.tar.gz
[[ -f $edk2_src ]] || die "no $edk2_src; run qemu/scripts/build-edk2.sh"
top=$(tar -tzf "$edk2_src" | head -1 | cut -d/ -f1)
mkdir -p "$licenses/edk2"
for f in "${edk2_files[@]}"; do
    tar -xzOf "$edk2_src" "$top/$f" >"$licenses/edk2/${f//\//_}" || die "edk2: no $f"
done

# The dbx comes from Microsoft's secureboot_objects at the pinned commit.
dbx_commit=$(jq -r .firmware.dbx.url "$LOCK" | sed -E 's|.*/secureboot_objects/([0-9a-f]+)/.*|\1|')
mkdir -p "$licenses/dbx-arm64"
curl -fsSL --retry 3 -o "$licenses/dbx-arm64/License.txt" \
    "https://raw.githubusercontent.com/microsoft/secureboot_objects/$dbx_commit/License.txt"

chmod 644 "$licenses"/*/*
echo "extract-licenses: $(find "$licenses" -type f | wc -l | tr -d ' ') files in $licenses"
