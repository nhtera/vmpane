# Windows guests

Windows 11 on Arm runs in VMPane on QEMU (Apple's Virtualization framework cannot run Windows). VMPane does
not provide Windows or a licence: you need a Windows 11 Arm64 ISO and, to activate Windows, a valid licence.

## Getting the ISO

- **From Microsoft, in VMPane**: VMPane opens Microsoft's own download page. You pick the language and accept
  Microsoft's terms there; VMPane saves the ISO and checks its SHA-256 against the one Microsoft's page lists.
  The setting *Download Windows inside VMPane* turns this off.
- **From Microsoft, in your browser**: open the page in Safari, Chrome or Firefox and download the Arm64 ISO.
  While the wizard waits, VMPane picks up the finished file (`Win11_…_Arm64.iso`) from `~/Downloads`.
- **Your own ISO**: any Windows 11 Arm64 install ISO.

VMPane reads the image list inside the ISO and refuses media that are not Arm64 (x64 media cannot boot on
Apple silicon) or not Windows 11 (build 22000 or later), and an edition the ISO does not have.

## Installing

The wizard asks for the edition, a local account (name and password), the computer name, the time zone and
keyboard (from your Mac), an optional product key, and your acceptance of
[Microsoft's licence terms](https://www.microsoft.com/en-us/useterms). Then the install runs on its own,
with no clicks, in about 40 minutes:

1. Windows Setup starts from the ISO (VMPane presses the "any key" the ISO asks for) and installs to the disk.
   The VM has **no network** during the install, so Windows creates the local account you chose instead of
   asking for a Microsoft account.
2. At Setup's first restart VMPane ejects the ISO, so Setup can never start over and wipe the disk.
3. Windows signs in once, removes the stored password, and runs the VMPane guest tools (drivers).
4. VMPane shuts the VM down, adds the network and the virtio display, and starts it again.

The install survives a quit, an app update or a Mac restart: VMPane records where it is in the VM and carries
on from there. If a step takes far too long, the automatic install stops: VMPane deletes the password image and
leaves the VM for you to finish (see below).

**The password** you choose goes into one file in the VM (`install/unattend.iso`, readable only by you), which
VMPane deletes as soon as the install ends, whether it succeeded, failed or was cancelled. It is never written
to the VM's settings or logs. Inside Windows the install removes its copies of the answer file and the
auto-sign-in password.

## Guest tools

The VMPANE_TOOLS disc holds the virtio drivers for Arm64 Windows 11 (storage, network, display, input,
serial ports, memory balloon, random numbers, crash reporting), from
[virtio-win](https://github.com/virtio-win/kvm-guest-drivers-windows), each checked against Microsoft's
signature before it is put on the disc. The install runs them for you. To run them again (for example after an
update), attach the disc and, in an administrator PowerShell:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File D:\install.ps1   # D: = the VMPANE_TOOLS drive
```

It logs to `C:\ProgramData\VMPane\tools-install.log`.

## Finishing by hand

If the automatic install stopped, the VM keeps what Windows already did. Open its window and:

- **Setup is still running or waiting**: follow Setup's screens. Without a network, choose *I don't have
  internet* to create a local account.
- **Windows is installed but has no network or a small screen**: attach the guest tools and run `install.ps1`
  as shown above, then shut Windows down and start the VM again.

## Limits

- No 3D acceleration (the display is a 2D virtio GPU).
- No nested virtualization: Hyper-V, WSL 2, Windows Sandbox and Virtualization-based Security do not run.
- Clipboard sharing and automatic resolution changes need the SPICE guest agent for Arm64 Windows, which the
  guest tools do not include yet.
- Windows activation is between you and Microsoft; VMPane neither provides nor checks keys.
