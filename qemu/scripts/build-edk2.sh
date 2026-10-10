#!/usr/bin/env bash
# Builds the UEFI firmware VMPane ships: EDK2 ArmVirtQemu (AARCH64) at the commit pinned in deps.lock, with
# Secure Boot and TPM 2.0 (QEMU's roms/edk2-build.config aa64 recipe plus SECURE_BOOT_ENABLE). EDK2 builds
# with GCC on Linux, so the build runs in an Ubuntu VM started with this pipeline's own QEMU (no Docker): a
# sha-pinned cloud image, apt pinned to a snapshot date, edk2 checked out and verified at the pinned commit.
#
# Output in qemu/build/firmware/ (unpadded; QEMU's pflash needs 64 MiB, so users of the files pad copies):
#   edk2-aarch64-code.fd   firmware code
#   vars-blank.fd          empty variable store (make-vars.sh enrolls the keys)
#   edk2-src.tar.gz        the exact source built (with submodules), for the corresponding-source bundle
#   build.log, edk2-build.log
#
# Usage: qemu/scripts/build-edk2.sh [--force]     (needs qemu/scripts/build-deps.sh first; ~10-20 min)
set -euo pipefail
source "$(dirname "$0")/lib/env.sh"

out=$BUILD/firmware
work=$BUILD/edk2-vm
key=$({ jq -c '.firmware | del(.comment)' "$LOCK"; cat "$0"; } | shasum -a 256 | cut -d' ' -f1)
if [[ ${1:-} != --force && -f $out/stamp && $(cat "$out/stamp") == "$key" ]]; then
    echo "build-edk2: up to date ($out)"
    exit 0
fi
[[ -f $SYSROOT/share/qemu/edk2-aarch64-code.fd ]] || die "no QEMU in the sysroot; run qemu/scripts/build-deps.sh"

commit=$(jq -r .firmware.edk2.commit "$LOCK")
tag=$(jq -r .firmware.edk2.version "$LOCK")
snapshot=$(jq -r .firmware.aptSnapshot "$LOCK")
epoch=$(jq -r .sourceDateEpoch "$LOCK")
image=$(fetch_firmware buildImage)

rm -rf "$work" "$out"
mkdir -p "$work" "$out"
# The build VM runs on this pipeline's QEMU, booted by the prebuilt EDK2 that QEMU ships (only for the VM).
"$QEMU_DIR/scripts/package.sh" --out "$work/qemu" --no-firmware >/dev/null
qemu=$work/qemu/bin
cp "$SYSROOT/share/qemu/edk2-arm-vars.fd" "$work/vm-vars.fd"
"$qemu/qemu-img" create -q -f qcow2 -b "$image" -F qcow2 "$work/disk.qcow2" 32G

# Output disk: FAT32 without a partition table, so macOS can mount it afterwards.
truncate -s 1g "$work/out.raw"
dev=$(hdiutil attach -imagekey diskimage-class=CRawDiskImage -nomount "$work/out.raw" | head -1 | awk '{print $1}')
newfs_msdos -F 32 -v EDK2OUT "$dev" >/dev/null
hdiutil detach "$dev" -quiet

seed=$work/seed
mkdir -p "$seed"
printf 'instance-id: vmpane-edk2-%s\nlocal-hostname: edk2-build\n' "$key" >"$seed/meta-data"
cat >"$seed/user-data" <<EOF
#cloud-config
write_files:
  - path: /root/build.sh
    permissions: '0755'
    content: |
      #!/bin/bash
      set -euxo pipefail
      exec > >(tee -a /root/build.log) 2>&1
      trap 'echo "EDK2BUILD fail at line \$LINENO"; cp /root/*.log /mnt/ 2>/dev/null; sync; poweroff' ERR
      echo "EDK2BUILD start"
      mount /dev/vdc /mnt
      export DEBIAN_FRONTEND=noninteractive
      apt-get -q --snapshot $snapshot update
      apt-get -yq --snapshot $snapshot install build-essential git uuid-dev acpica-tools python3 python3-venv \\
        python-is-python3
      echo "EDK2BUILD packages \$(gcc --version | head -1)"
      mkdir -p /root/edk2 && cd /root/edk2
      git init -q && git remote add origin $(jq -r .firmware.edk2.url "$LOCK")
      git fetch -q --depth 1 origin $commit && git checkout -q FETCH_HEAD
      test "\$(git rev-parse HEAD)" = $commit
      # Zeex/subhook (unit tests only) is no longer fetchable; the rest is pinned by the superproject commit.
      git submodule init -q
      git config submodule.UnitTestFrameworkPkg/Library/SubhookLib/subhook.update none
      git submodule update -q --depth 1 || git submodule update -q
      echo "EDK2BUILD source $tag \$(git rev-parse HEAD)"
      git ls-files -z --recurse-submodules | tar --null -T - --sort=name --mtime=@$epoch --owner=0 --group=0 \\
        --numeric-owner --transform 's,^,edk2-$tag/,' -cf - | gzip -n -9 >/mnt/edk2-src.tar.gz
      # The firmware banner uses __DATE__/__TIME__; GCC takes them from SOURCE_DATE_EPOCH.
      export SOURCE_DATE_EPOCH=$epoch
      make -C BaseTools/Source/C -j\$(nproc) >/root/basetools.log 2>&1
      set +u; . ./edksetup.sh; set -u
      build -a AARCH64 -t GCC5 -b RELEASE -n \$(nproc) -p ArmVirtPkg/ArmVirtQemu.dsc \\
        -D NETWORK_HTTP_BOOT_ENABLE=TRUE -D NETWORK_IP6_ENABLE=TRUE -D NETWORK_TLS_ENABLE=TRUE \\
        -D NETWORK_ISCSI_ENABLE=TRUE -D NETWORK_ALLOW_HTTP_CONNECTIONS=TRUE \\
        -D TPM2_ENABLE=TRUE -D TPM2_CONFIG_ENABLE=TRUE -D TPM1_ENABLE=TRUE -D CAVIUM_ERRATUM_27456=TRUE \\
        -D DEBUG_PRINT_ERROR_LEVEL=0x80000000 -D SECURE_BOOT_ENABLE=TRUE \\
        --pcd PcdDxeNxMemoryProtectionPolicy=0xC000000000007FD1 --pcd PcdUninstallMemAttrProtocol=TRUE \\
        >/root/edk2-build.log 2>&1
      fv=Build/ArmVirtQemu-AARCH64/RELEASE_GCC5/FV
      cp \$fv/QEMU_EFI.fd /mnt/edk2-aarch64-code.fd
      cp \$fv/QEMU_VARS.fd /mnt/vars-blank.fd
      echo "EDK2BUILD built"
      cp /root/*.log /mnt/
      sync && umount /mnt
      echo "EDK2BUILD done"
      poweroff
runcmd:
  - [bash, /root/build.sh]
EOF
hdiutil makehybrid -quiet -o "$work/seed.iso" "$seed" -iso -joliet -default-volume-name cidata

echo "build-edk2: $tag in an Ubuntu VM (serial: $work/serial.log)"
"$qemu/qemu-system-aarch64" -L "$work/qemu/share/qemu" -machine virt -accel hvf -cpu host -smp "$(sysctl -n hw.perflevel0.physicalcpu)" -m 8G \
    -drive if=pflash,format=raw,readonly=on,file="$SYSROOT/share/qemu/edk2-aarch64-code.fd" \
    -drive if=pflash,format=raw,file="$work/vm-vars.fd" \
    -drive if=virtio,format=qcow2,file="$work/disk.qcow2" -drive if=virtio,format=raw,readonly=on,file="$work/seed.iso" \
    -drive if=virtio,format=raw,file="$work/out.raw" \
    -nic user,model=virtio-net-pci -display none -monitor none -serial file:"$work/serial.log" 2>"$work/qemu.err" &
vm=$!
trap 'kill $vm 2>/dev/null || true' EXIT
start=$SECONDS
last=
while kill -0 $vm 2>/dev/null; do
    sleep 10
    line=$(grep -ao 'EDK2BUILD [a-z].*' "$work/serial.log" 2>/dev/null | tail -1 | tr -d '\r' || true)
    [[ $line != "$last" ]] && echo "  $((SECONDS - start)) s: $line" && last=$line
    ((SECONDS - start < 3600)) || die "EDK2 build VM still running after 60 min"
done
trap - EXIT

mnt=$(mktemp -d)
hdiutil attach -imagekey diskimage-class=CRawDiskImage -readonly -nobrowse -mountpoint "$mnt" "$work/out.raw" >/dev/null
cp "$mnt"/* "$out/" 2>/dev/null || true
hdiutil detach "$mnt" -quiet
rmdir "$mnt"
[[ -f $out/edk2-aarch64-code.fd && -f $out/vars-blank.fd ]] ||
    die "the VM produced no firmware; see $out/build.log and $work/serial.log"
chmod 644 "$out"/*
echo "$key" >"$out/stamp"
rm -rf "$work"
(cd "$out" && shasum -a 256 edk2-aarch64-code.fd vars-blank.fd edk2-src.tar.gz)
echo "build-edk2: done in $((SECONDS - start)) s"
