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

In **New VM** (⌘N), choose **Windows 11**: **Customize…** (or Return) goes to the ISO. An ISO dropped on the library
or VMPane's Dock icon opens New VM with it, and is checked first: "This is an x64 ISO. VMPane needs Windows 11 for
Arm (ARM64)." VMPane reads the image list inside the ISO and refuses media that are not Arm64 (x64 media cannot boot on
Apple silicon) or not Windows 11 (build 22000 or later), and an edition the ISO does not have.

## Installing

The wizard asks for the edition, a local account (name and password), the computer name, the time zone and
keyboard (from your Mac), an optional product key, and your acceptance of
[Microsoft's licence terms](https://www.microsoft.com/en-us/useterms). Then the install runs on its own,
with no clicks, in about 10 minutes (7 on an M4 Pro Mac, Windows 11 build 26300):

1. Windows Setup starts from the ISO (VMPane presses the "any key" the ISO asks for) and installs to the disk.
   The VM has **no network** during the install, so Windows creates the local account you chose instead of
   asking for a Microsoft account.
2. At Setup's first restart VMPane ejects the ISO, so Setup can never start over and wipe the disk.
3. Windows signs in once, removes the stored password, and runs the VMPane guest tools (drivers).
4. VMPane shuts the VM down, adds the network and the virtio display, and starts it again.

The install survives a quit, an app update or a Mac restart: VMPane records where it is in the VM and carries
on from there. If a step takes far too long, the automatic install stops: VMPane deletes the password image and
leaves the VM for you to finish (see below). *Cancel install* ends it and shuts the VM down.

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

A Windows VM without the guest tools (imported, or set up by hand) offers them at the top of its window once it
has run a while (or **VM › Install Guest Tools…**): **Attach Tools Disc** attaches the VMPANE_TOOLS disc from
the VM's next start (a running VM takes no new disc, and restarting Windows keeps the same VM running): shut
Windows down, start the VM again, then run `install.ps1` as above. After
that, a newer VMPane updates the agent by itself, without the disc (**Keep the guest tools up to date** in the
VM's settings, General; **VM › Update Guest Tools** does it at once); the drivers stay as `install.ps1` put them.

The disc also holds the VMPane guest agent (`vmpane-agent.msi`), which shares the clipboard and files with your
Mac (see below). Unlike the drivers it is not code-signed for
Windows (VMPane has no Windows signing certificate), so if you install it by hand Windows names its publisher
as unknown. Each release's agent is built on GitHub and carries a build attestation:
`gh attestation verify vmpane-agent.msi --repo nhtera/vmpane` checks yours.

## Finishing by hand

If the automatic install stopped, the VM keeps what Windows already did. Windows Setup may still hold a copy
of its answers, password included, so change the account's password once you are signed in. Open the VM's
window and:

- **Setup is still running or waiting**: follow Setup's screens. Without a network, choose *I don't have
  internet* to create a local account.
- **Windows is installed but has no network or a small screen**: attach the guest tools and run `install.ps1`
  as shown above, then shut Windows down and start the VM again.

## Clipboard and files

With someone signed in to Windows and the VM's window in front, the clipboard goes both ways (Settings › Sharing ›
**Clipboard**):

- **Text and formatted text.** Plain text always; with **Keep text formatting** (on unless you turn it off),
  bold, links, colours, fonts and tables too, as HTML and RTF, so Word, Outlook, Excel and browsers paste them
  formatted.
- **Images** both ways (PNG on the Mac; PNG and a bitmap in Windows).
- **Files and folders.** Copied in Finder, ⌘C: in the VM, Ctrl-V in Explorer pastes them into the open folder.
  Copied in Explorer: on the Mac, ⌘V in Finder pastes them where you are. Each copy carries up to 1000 files and
  2 GB; for more, drag them onto the VM's window or use a shared folder. A copy waits in a staging folder on the
  other side (in Windows `%LOCALAPPDATA%\Temp\VMPane Clipboard`, on the Mac in `~/Library/Caches`) until the next
  copy replaces it; files from the VM are marked as downloaded, so macOS checks them before they first open.

**Dragging files.** Files dropped on the VM's window land in **Desktop › VMPane Drops**. Files dragged in Explorer
out of the VM's window go on as a drag on the Mac: drop them in Finder, and they are copied there from the VM. A
drag out never moves anything in Windows.

## Sound and microphone

Windows plays through the Mac's output (Settings › Sharing › **Sound output**), and with **Microphone** on it gets a
microphone fed by the Mac's: the VM's window process plays and records it over SPICE, and QEMU never touches the Mac's
audio. The Mac's microphone is open only while something in Windows records (its menu bar shows it then). The first
time that happens, macOS asks whether "VMPane VM" may use the microphone; it can be a VM running without its window,
or one an agent uses, so the question may come while you are not looking at it. Until you allow it (System Settings ›
Privacy & Security › Microphone), Windows records silence.

## Limits

- No 3D acceleration (the display is a 2D virtio GPU).
- No nested virtualization: Hyper-V, WSL 2, Windows Sandbox and Virtualization-based Security do not run.
- Automatic resolution changes need the SPICE guest agent for Arm64 Windows, which the guest tools do not
  include yet.
- Windows activation is between you and Microsoft; VMPane neither provides nor checks keys.
