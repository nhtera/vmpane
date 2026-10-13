# Linux guests

## Installing

Create a Linux VM from the catalog (Ubuntu Server, Debian, Fedora Server; arm64 ISOs, checked against a
pinned SHA-256 after download) or from your own ISO. VMPane refuses ISOs without an arm64 UEFI loader
(`EFI/BOOT/BOOTAA64.EFI`): x86_64 images cannot boot on Apple silicon.

The ISO is attached as a USB drive. When the installer reboots, the installed system starts; the ISO stays
attached until the VM next stops, then VMPane removes it from the VM's settings.

- The boot loader's menu (GRUB, the first seconds) is small: it picks the largest screen the VM's display offers.
  Linux and its installer then use the window's size.
- Ubuntu's installer, after *Reboot Now*, waits on "Please remove the installation medium, then press ENTER",
  which its screen can hide: press Enter in the VM's window.

## Display size

A new Linux VM gets one pixel per point of its window (Settings → Display → Scaling: *Larger*), so the
installer and text consoles are readable on a Retina screen; the guest's resolution follows the window. *Sharp
(Retina pixels)* gives the guest every pixel instead: crisper, but a console's text is half the size, and a desktop
then needs its own scaling (GNOME: Settings → Displays → Scale 200%). The change applies at the next start.

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

Choose **Rosetta (run x86-64 Linux programs)** when you create the VM (New VM › Integrations; VMPane asks
macOS to install Rosetta if needed). Then, in the guest:

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

*Planned.* VMs support nested virtualization on a Mac with an M3 chip or later (the guest then has `/dev/kvm`,
for KVM, QEMU with acceleration, or Firecracker inside the VM), but the app has no switch for it yet.
