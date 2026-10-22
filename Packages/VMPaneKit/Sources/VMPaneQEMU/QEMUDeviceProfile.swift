import VMPaneCore

/// The fixed hardware of a QEMU guest type, from the Gate 00 spikes (S1, S2). What varies per VM (CPUs,
/// memory, disks, NICs, display device, TPM, audio) comes from the config in `QEMUArgvBuilder`.
public enum QEMUDeviceProfile: Sendable, Equatable {
    /// Windows 11 ARM: Secure Boot EDK2, TPM 2.0 on swtpm, NVMe root disk, USB keyboard and tablet.
    case windows11

    public static func `for`(_ os: GuestOS) -> QEMUDeviceProfile? {
        os == .windows ? .windows11 : nil
    }

    /// `-machine` options. GICv3 is what S1 ran with.
    var machine: String { "virt,highmem=on,gic-version=3" }

    /// `tpm-tis-device` needs `ppi=off`: the default maps a 0x400-byte RAM region that HVF cannot map
    /// (16 KiB pages) and QEMU aborts. Windows then reports no PPI (`Get-Tpm` errors); Setup and BitLocker work.
    var tpmDevice: String { "tpm-tis-device,tpmdev=tpm0,ppi=off" }

    /// The QEMU RTC runs in UTC; Windows expects local time.
    var rtc: String { "base=localtime" }

    /// Keyboard and absolute pointer on XHCI (inbox drivers, work in firmware and Setup). Removable media
    /// (usb-storage) share its USB 2 ports: the default 4 leave room for two discs, an install needs three.
    var inputDevices: [String] { ["qemu-xhci,id=xhci,p2=8,p3=8", "usb-kbd,bus=xhci.0", "usb-tablet,bus=xhci.0"] }

    /// HDA with the inbox Windows driver (S2), on the `spice` audiodev: the helper plays and records through SPICE
    /// (QEMU's CoreAudio backend cannot record). A speaker, plus a microphone (`hda-micro`, which Windows names
    /// "Microphone") when the VM's microphone setting is on.
    func audioDevices(microphone: Bool) -> [String] {
        ["intel-hda,id=hda", microphone ? "hda-micro,bus=hda.0,audiodev=snd0" : "hda-output,bus=hda.0,audiodev=snd0"]
    }
}
