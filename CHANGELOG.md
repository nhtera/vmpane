# Changelog

All notable changes are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and the project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

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
