# Changelog

All notable changes are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and the project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [1.0.0-beta.11]
AI agents act faster and see more, with you able to take over at any moment; Linux VMs are ready in minutes; the
library and the new-VM sheet are rebuilt; the clipboard keeps formatting and carries files both ways; and Windows VMs
get a microphone.

### Added
- `vm_actions`: up to 50 keys, typing, clicks, drags, scrolls and waits in one call, each decided and audited as
  its own request, and every input tool says whether the screen changed (`verified`, with where). `vm_power start`
  can wait for the guest tools.
- `vm_read_screen`: the text on any guest's screen (recognised on the Mac), and its controls on Windows (UI
  Automation) and macOS (Accessibility), to click by id; marked as the guest's text, never instructions.
- `vm_exec` with `desktop` opens an app on the signed-in user's desktop (all three guests); `vm_sign_in` signs a
  locked guest in with a password VMPane keeps and types itself, never shown to the agent (off per VM; at Run
  commands and Full control you are asked first).
- Linux VMs from Ubuntu 26.04, Debian 13 and Fedora 44 cloud images: nothing to click through, guest tools and SSH
  (on 127.0.0.1) ready on the first boot, with an optional GNOME desktop.
- The VM's window shows an AI agent at work: who, at what level, what it just did, with **Take Over** and **Stop**.
  Typing or clicking in the VM while an agent acts takes over too; agents wait (`takenOver`) until you resume. Agents' questions appear
  in the VM's window.
- A new library: thumbnails, a list or a grid, filters, an inspector (system, resources, snapshots, activity), and
  a stopped VM's processors, memory, display, disk and snapshots changed without starting it.
- New VM is one sheet of system cards sized for your Mac (⌘N, then Return makes another of the last one), made in
  the background with each stage in the library. Drop an .iso or .ipsw on the library or the Dock icon to start
  from it. A Linux VM made from a card gets a password VMPane keeps for you (**Copy Password** in the inspector).
- The clipboard of macOS and Windows VMs keeps formatting: bold, links, colours, fonts and tables copied in Word,
  Outlook, Excel or a browser paste formatted on the other side (HTML and RTF, with plain text alongside; **Keep text
  formatting** in Settings › Sharing turns it off) (#6).
- Files and folders copy and paste both ways: ⌘C in Finder, Ctrl-V in Explorer pastes them into the open folder, and
  files copied in the VM paste where you press ⌘V in Finder (up to 1000 files and 2 GB a copy) (#6).
- Files dragged out of a Windows VM's window drop in Finder, copied from the VM; nothing moves in Windows (#6).

### Changed
- Files copied in a VM no longer land in `~/Downloads/VMPane/<VM>`: they wait in a staging folder until pasted,
  and the next copy replaces them.
- Downloads can be cancelled and resume later; a VM appears in the library only once its downloads are done, so a
  quit midway leaves none behind.
- Keys or mouse buttons an agent left held down are let go when you take over or the agent leaves.

### Fixed
- Windows VMs had no microphone: QEMU's CoreAudio backend only plays sound, so Windows got a speaker and nothing to
  record from. Their sound now goes over SPICE to the VM's own window process, which plays it and, with Microphone
  on, gives Windows a microphone fed by the Mac's; QEMU no longer reaches the Mac's audio at all (#7). macOS asks
  once whether "VMPane VM" may use the microphone, the first time Windows records. A Windows VM suspended or
  snapshotted before this version with Microphone on may show its microphone only after Windows restarts.
- Cancelling a Parallels import or a cloud-image create just before its conversion started could crash VMPane.

## [1.0.0-beta.10]
Windows VMs on the shared network resolve names, and Windows VMs share the clipboard.

### Added
- Windows VMs share the clipboard through VMPane's guest agent: text and images both ways, and files copied in
  the VM arrive in `~/Downloads/VMPane/<VM>`. Existing VMs get it by updating the guest tools (#5).

### Fixed
- A Windows VM on the shared (NAT) network could not resolve names: QEMU's sandbox kept it from reading the Mac's
  DNS servers, so the network's DNS (10.0.2.3) never answered. The same sandbox rule filled `qemu.log` with
  thousands of "Conversion from character set" lines (#5).

## [1.0.0-beta.9]
VMPane warns when the Mac is low on memory for a VM.

### Added
- VMPane asks before starting a VM that can use more memory than the Mac has available (Cancel or Start Anyway),
  and a running VM's window warns while the Mac is almost out of memory. `vmpane start` prints the same warning.
  On a Mac out of memory, Linux VMs crashed or froze with memory that changed under them (e.g. a Debian install
  stuck at "Scanning the mirror"); the same VMs ran cleanly once memory was free.

## [1.0.0-beta.8]
The new-VM wizard starts with macOS chosen, and a VM closed during a Windows install stays as it was left.

### Changed
- The new-VM wizard opens with macOS chosen, so Continue works at once; click Linux or Windows 11 to change it.

### Fixed
- A VM's process that shut down during an automatic Windows install could still write the install's progress or
  the VM's settings after letting go of the VM, and start the VM again if the install had just finished. It now
  finishes that work first and leaves the VM off; the next start continues from there.

## [1.0.0-beta.7]
A Linux VM's text keeps its size when its resolution changes while it runs.

### Fixed
- A resolution changed in a running Linux VM's settings reached the VM in pixels, not in points as at its start, so
  at Standard scaling a desktop or installer (e.g. Debian's) redrew its text at half its size until the VM restarted
  or its window was resized.

## [1.0.0-beta.6]
The new-VM wizard no longer looks as if macOS were chosen.

### Fixed
- With keyboard navigation on, the new-VM wizard opened with a focus ring on the macOS card that looked like a
  choice, and the ring stayed there after a click on another system. Focus now follows the chosen system, and the
  chosen card shows one border, not two.

## [1.0.0-beta.5]
A Linux VM's boot menu is readable too.

### Fixed
- A Linux VM's boot menu (GRUB) and first boot messages are readable: VMPane shows the top-left corner of the VM
  firmware's 8192 × 4320 boot screen at one guest pixel per point until Linux sets the VM's own size.
- An AI agent's file transfer or command cut by the kill switch ends with a result the agent can read, not a
  protocol error, when the switch closes its connection before the transfer's own answer arrives.
- The kill switch stops an agent's command that was still waiting (for the person's answer, the session's undo
  snapshot or the VM to start it), also when the app lets agents act again before the wait ends.

## [1.0.0-beta.4]
A Linux VM's boot and installer are readable from the start.

### Fixed
- A Linux VM with Larger scaling starts at its size in points, so its boot messages and installer are readable
  from the start (only the boot loader's own menu, e.g. GRUB, still picks the largest screen and shows small).

## [1.0.0-beta.3]
A readable Linux display, a menu bar and clean Quit for each VM, and an install guide in the disk image.

### Changed
- VoiceOver finds a VM's screen (named after the VM), and the settings' "Live" and "Next start" badges are
  easier to read.
- A new Linux VM gets one pixel per point of its window, so the installer and consoles are readable on a Retina
  screen (they were half size). Settings → Display → Scaling now applies to Linux VMs too.
- The disk image shows how to install: VMPane beside the Applications folder, with an arrow to drag it there.

### Fixed
- A VM's own app ("VMPane VM") has a menu bar: Quit, Hide, Edit and Window (⌘ keys typed into the VM's screen
  still go to the VM). Quitting it, also from its Dock tile, asks first while the VM runs and then shuts the VM
  down cleanly; before, it had no menu and a Quit from the Dock ended a running VM at once.

## [1.0.0-beta.2]
Fixes for the first beta.

### Fixed
- Deleting or cloning a VM that was shut down from its own window works: VMPane first quits the VM's process,
  which stays open after the VM stops (1.0.0-beta.1 refused with "VMRunning()").
- A Windows VM's guest agent comes back at once after the VM resumes from a suspend or a live snapshot is
  restored, without a Windows restart (works with the 1.0.0-beta.1 agent too).
- The VMPane folder in Application Support is private (0700) again: 1.0.0-beta.1 could make it readable by other
  accounts on the Mac (the files in it were already private). `vmpane doctor` reported it.

## [1.0.0-beta.1]
The first public beta.

### Added
- macOS and Linux guests on Virtualization.framework: install macOS from an Apple restore image (IPSW) and Linux
  from an ISO; suspend and resume; live and offline snapshots.
- Windows 11 ARM guests on QEMU with Hypervisor.framework, a software TPM and Secure Boot; an unattended install
  from your own ISO that resumes after an interruption.
- The VMPane guest agent for Linux, macOS and Windows: shared clipboard, drag and drop of files, file transfer
  and commands.
- Shared folders and port forwarding.
- Import of Parallels Desktop VMs.
- The `vmpane` command-line tool and a built-in MCP server (`vmpane mcp`): AI coding agents drive only the VMs
  you open to them, at the level you choose (every VM starts at Off), and the kill switch stops them all.
- Updates through Sparkle; VMPane asks before installing one, and running VMs keep running.
