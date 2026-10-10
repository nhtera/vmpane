# QEMU devices and their attack surface

A guest controls every device model QEMU gives it, so each device compiled into `qemu-system-aarch64` is
code a malicious guest can reach. VMPane builds QEMU with `--without-default-devices` and the allowlist in
[`configs/devices-vmpane.mak`](configs/devices-vmpane.mak); everything else is not in the binary at all.
The `virt` board and the devices it selects (GIC, PCIe host bridge, pflash, PL011/PL031/PL061, fw_cfg with
ramfb, virtio-mmio, SMMUv3, ACPI) come with the board.

The binary has no TCG (`--disable-tcg`): it can only run guests with HVF, so a VM cannot silently fall
back to software emulation, and the TCG code (the largest single part of QEMU) is not there to attack.

| Device (Kconfig) | Used for |
|---|---|
| `NVME_PCI` | Windows system disk |
| `VIRTIO_BLK` | Linux disks, extra data disks |
| `USB_STORAGE_CLASSIC` | install ISO, unattend/tools ISOs, removable disks |
| `VIRTIO_PCI`, `VIRTIO_NET` | networking (slirp) |
| `VIRTIO_SERIAL` | SPICE vdagent and VMPane agent channels |
| `VIRTIO_RNG`, `VIRTIO_BALLOON` | entropy, memory reporting |
| `VIRTIO_GPU` | display after viogpudo is installed (ramfb before) |
| `USB_XHCI_PCI`, `USB_HID` | keyboard and absolute pointer |
| `USB_NETWORK` | networking without drivers during Windows setup (optional profile) |
| `USB_AUDIO`, `HDA` | sound (intel-hda + hda-output/hda-duplex: inbox Windows driver) |
| `TPM_TIS_SYSBUS`, `TPM_EMULATOR` | TPM 2.0 for Windows 11, backed by swtpm |
| `PVPANIC_PCI` | guest crash reporting |

USB passthrough (`usb-host`, libusb) and SPICE USB redirection (`usb-redir`, usbredir) are built in; they
expose a host device only when the user attaches one.

Left out on purpose: VNC (the display is SPICE; screenshots use QMP), every network backend except slirp
(no vmnet, vde), remote block drivers (curl, iSCSI, NFS, RBD, ssh), and the guest agent, user-mode
emulation and plugins.

libcrypto records `OPENSSLDIR=/vmpane/qemu/ssl` (the build prefix), which it would read configuration
from. The directory does not exist on users' Macs, and OpenSSL is built with `no-module`, so nothing can be
loaded from there; creating `/vmpane` needs administrator rights.

## Review each release

1. Check the QEMU security advisories (<https://www.qemu.org/contribute/security-process/>) and the CVEs
   fixed since the pinned version for the devices above and for slirp, SPICE and usbredir.
2. If one applies, move to the fixed QEMU (or patch) in a dedicated change with the `qemu-smoke` and
   Windows boot itests.
3. Record the review (date, QEMU version, outcome) below.

| Date | QEMU | Outcome |
|---|---|---|
| 2026-10-10 | 11.1.2 | Initial allowlist; boots EDK2 under HVF with the trimmed device set |
