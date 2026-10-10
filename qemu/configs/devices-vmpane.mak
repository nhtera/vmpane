# Devices compiled into VMPane's qemu-system-aarch64 (configure --without-default-devices). Only what the
# Windows/Linux VM profiles use: every device left out is guest-reachable code that cannot be attacked.
# Track QEMU CVEs for these devices (qemu/SECURITY-DEVICES.md).
#
# Board: virt selects its own core (GIC, ACPI, PCIe host, pflash, PL011, fw_cfg + ramfb, virtio-mmio).
CONFIG_ARM_VIRT=y
# virt implies these; keep them out.
CONFIG_PCI_DEVICES=n
CONFIG_TEST_DEVICES=n

# Storage: NVMe system disk; install media and removable disks over USB.
CONFIG_NVME_PCI=y
CONFIG_VIRTIO_BLK=y
CONFIG_USB_STORAGE_CLASSIC=y

# virtio (drivers from virtio-win in Windows, inbox in Linux).
CONFIG_VIRTIO_PCI=y
CONFIG_VIRTIO_NET=y
CONFIG_VIRTIO_SERIAL=y
CONFIG_VIRTIO_RNG=y
CONFIG_VIRTIO_BALLOON=y
CONFIG_VIRTIO_GPU=y

# USB: xHCI with keyboard/tablet, usb-net (driverless network during Windows setup), usb-audio.
CONFIG_USB_XHCI_PCI=y
CONFIG_USB_HID=y
CONFIG_USB_NETWORK=y
CONFIG_USB_AUDIO=y

# Audio: intel-hda + hda-output/hda-duplex (inbox Windows driver).
CONFIG_HDA=y

# TPM 2.0 (Windows 11) through swtpm.
CONFIG_TPM_TIS_SYSBUS=y
CONFIG_TPM_EMULATOR=y

# Guest crash reporting.
CONFIG_PVPANIC_PCI=y
