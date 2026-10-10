#!/usr/bin/env bash
# Writes the Secure Boot variable store that each new VM starts from (Windows 11 Setup requires Secure
# Boot):
#   PK   VMPane's own certificate (qemu/firmware/vmpane-pk.pem; its private key was destroyed when it was
#        made, so nothing can ever be signed with it)
#   KEK  Microsoft KEK CA 2011 + 2023 (and the VMPane certificate)
#   db   Microsoft Windows PCA 2011, Windows UEFI CA 2023, UEFI CA 2011 + 2023, Option ROM UEFI CA 2023
#   dbx  Microsoft's arm64 revocation list (pinned in deps.lock)
# and Secure Boot enabled.
#
# Input: qemu/build/firmware/vars-blank.fd (build-edk2.sh). Output: qemu/build/firmware/edk2-aarch64-vars-sb.fd
# (unpadded, like the code file). Usage: qemu/scripts/make-vars.sh
set -euo pipefail
source "$(dirname "$0")/lib/env.sh"

firmware=$BUILD/firmware
[[ -f $firmware/vars-blank.fd ]] || die "no $firmware/vars-blank.fd; run qemu/scripts/build-edk2.sh"
[[ -x $TOOLS/venv/bin/virt-fw-vars ]] || die "no virt-fw-vars; run qemu/scripts/build-deps.sh"
dbx=$(fetch_firmware dbx)
pk=$REPO_DIR/$(jq -r .firmware.pk "$LOCK")
out=$firmware/edk2-aarch64-vars-sb.fd

"$TOOLS/venv/bin/virt-fw-vars" --loglevel warning --input "$firmware/vars-blank.fd" --output "$out" \
    --enroll-cert "$pk" --microsoft-kek all --microsoft-db all --set-dbx "$dbx" --secure-boot >/dev/null
chmod 644 "$out"
# What is enrolled, for the build log.
"$TOOLS/venv/bin/virt-fw-vars" --input "$out" --print 2>/dev/null |
    grep -E '^ *(name|PK|KEK|db|dbx|SecureBoot|subject|cert|.*CN=)' | sed 's/^/  /' | head -40 || true
echo "make-vars: $out ($(shasum -a 256 "$out" | cut -d' ' -f1))"
