# Linux guests

## Ready in minutes: cloud images

**New VM** (⌘N) › **Ubuntu**, **Debian** or **Fedora** › **Create** makes a VM from the distribution's own arm64
cloud image (Ubuntu 26.04 LTS, Debian 13, Fedora 44) with nothing to click through. The account is your Mac's user
name with a password VMPane makes up and keeps for you (**Copy Password** in the VM's inspector); **Customize…**
lets you choose the name, a password of your own, an SSH public key, a desktop, the resources and the rest. ⌘N then
Return makes another of the system you used last.

- The image is downloaded once and checked against the SHA-256 pinned in VMPane, then converted to a disk once (in
  `~/Library/Caches/app.vmpane.mac/Cloud/`); each VM's disk is an APFS clone of it, grown to the size you chose.
  The pins come from Ubuntu's and Fedora's signed checksum lists; Debian publishes its cloud images' checksums over
  HTTPS only, unsigned (`scripts/refresh-linux-catalog.sh`).
- The first boot (cloud-init) creates your user as an administrator (`sudo`; `wheel` on Fedora), grows the disk,
  sets the host name from the VM's name and installs VMPane's guest tools from the VM's `vmpane-tools` share. It
  takes about a minute; the VM's window shows the progress. The password reaches the VM only as a `$6$` hash.
- With a key, SSH accepts only the key; without, it accepts the password. VMPane forwards SSH from 127.0.0.1 on
  this Mac only: `vmpane ssh <vm> -u <user>`.
- *Install a desktop* adds GNOME (Ubuntu's minimal desktop, Debian's GNOME task, Fedora Workstation) during the
  first boot, with automatic login, and restarts once: several minutes and a few GB more, downloaded by the VM.
- The setup data (`install/cidata*` in the VM's bundle) is removed once the guest tools run, and so are
  cloud-init's copies of it in the VM (`user-data.txt`, `cloud-config.txt`; its root-only cache keeps the
  password's hash, as `/etc/shadow` does). Until then the VM cannot be snapshotted. A copy made before that is a new
  machine with its own setup, and every copy gets its own SSH port.

## Installing from an ISO

Create a Linux VM from the catalog (**Customize…** › Installer: Ubuntu Server, Debian, Fedora Server; arm64 ISOs,
checked against a pinned SHA-256 after download) or from your own ISO, chosen there or dropped on the library or
VMPane's Dock icon. VMPane refuses ISOs without an arm64 UEFI loader
(`EFI/BOOT/BOOTAA64.EFI`): x86_64 images cannot boot on Apple silicon.

The ISO is attached as a USB drive. When the installer reboots, the installed system starts; the ISO stays
attached until the VM next stops, then VMPane removes it from the VM's settings.

- Until Linux starts its display driver, the screen is the VM firmware's: Apple's firmware always starts at
  8192 × 4320 and has no setting for it, and boot loaders such as GRUB keep it. VMPane shows that screen's
  top-left corner, where the firmware, GRUB's menu and the first boot messages are, at a readable size; the
  rest (GRUB's countdown, at the bottom) is off screen. GRUB redraws slowly at that size: a key takes a second
  or two to show. Linux and its installer then use the window's size.
- Ubuntu's installer, after *Reboot Now*, waits on "Please remove the installation medium, then press ENTER",
  which its screen can hide: press Enter in the VM's window.

A Linux installed from an ISO has no guest tools at first. Once the VM has run a while without them, its window
offers them (or **VM › Install Guest Tools…**): open a terminal in the VM and run the command it shows, or let
**Type in the VM** type it, then press Return:

```sh
sudo mkdir -p /mnt/vmpane-tools && (mountpoint -q /mnt/vmpane-tools || sudo mount -t virtiofs vmpane-tools /mnt/vmpane-tools) && sudo /mnt/vmpane-tools/install.sh
```

After that, a newer VMPane updates them by itself (**Keep the guest tools up to date** in the VM's settings,
General; **VM › Update Guest Tools** does it at once).

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
