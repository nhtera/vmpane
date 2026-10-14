# Changelog

All notable changes are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and the project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [1.0.0-beta.5]
A Linux VM's boot menu is readable too.

### Fixed
- A Linux VM's boot menu (GRUB) and first boot messages are readable: VMPane shows the top-left corner of the VM
  firmware's 8192 × 4320 boot screen at one guest pixel per point until Linux sets the VM's own size.

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
