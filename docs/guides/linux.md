# Linux guests

## Installing

Create a Linux VM from the catalog (Ubuntu Server, Debian, Fedora Server; arm64 ISOs, checked against a
pinned SHA-256 after download) or from your own ISO. VMPane refuses ISOs without an arm64 UEFI loader
(`EFI/BOOT/BOOTAA64.EFI`): x86_64 images cannot boot on Apple silicon.

The ISO is attached as a USB drive. When the installer reboots, the installed system starts; the ISO stays
attached until the VM next stops, then VMPane removes it from the VM's settings.

## Shared folders

Every shared folder of a VM appears under one virtiofs tag, `vmpane-shares`, one directory per share:

```sh
sudo mkdir -p /mnt/vmpane
sudo mount -t virtiofs vmpane-shares /mnt/vmpane
ls /mnt/vmpane        # one directory per shared folder, by its name
```

To mount at boot, add to `/etc/fstab`:

```
vmpane-shares  /mnt/vmpane  virtiofs  rw,nofail  0  0
```

A share added while the VM runs appears in the mounted directory without remounting, if the VM started
with at least one share; otherwise it appears after the next start.

## Rosetta (x86_64 Linux programs)

Turn on Rosetta in the VM's settings (VMPane asks macOS to install Rosetta if needed; restart the VM).
Then, in the guest:

```sh
sudo mkdir -p /media/rosetta
sudo mount -t virtiofs rosetta /media/rosetta
sudo /usr/sbin/update-binfmts --install rosetta /media/rosetta/rosetta \
    --magic "\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x3e\x00" \
    --mask "\xff\xff\xff\xff\xff\xfe\xfe\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff" \
    --credentials yes --preserve no --fix-binary yes
```

`update-binfmts` comes with the `binfmt-support` package (Debian, Ubuntu). To mount at boot, add to
`/etc/fstab`:

```
rosetta  /media/rosetta  virtiofs  ro,nofail  0  0
```

The `binfmt` registration follows Apple's documentation; VMPane's tests check that the `rosetta` share
mounts and holds the Rosetta binary.

## Nested virtualization

On a Mac with an M3 chip or later, turn on nested virtualization in the VM's settings (restart the VM).
The guest then has `/dev/kvm`, for KVM, QEMU with acceleration, or Firecracker inside the VM. On earlier
chips the option is not shown.
