# Overview

VMPane is a native macOS app for running virtual machines on a Mac with Apple silicon: macOS, Linux and
Windows 11 on Arm, each in its own Mac window, and a built-in MCP server so AI agents can use a VM within limits
you set. It is free and open source (Apache-2.0). VMPane is pre-alpha: public betas come first.

## Three guests, two engines

| Guest | Runs on | From |
|---|---|---|
| macOS | Apple's Virtualization framework | Apple's restore image (IPSW): from VMPane's catalog, or one you have |
| Linux | Apple's Virtualization framework | Ubuntu Server, Debian or Fedora Server from the catalog, or your own arm64 ISO |
| Windows 11 on Arm | QEMU with Hypervisor.framework, a software TPM 2.0 and Secure Boot | Your Windows 11 Arm64 ISO, installed with no clicks |

Each running VM is its own process (`VMPaneVM.app`), with its own window and Dock tile: a crash takes down one
VM, not VMPane. See [Architecture](architecture.md).

## What you can do with a VM

- **Snapshots**: live snapshots of a running VM keep its memory; a stopped VM's snapshot keeps its disks.
- **Shared folders** from your Mac, **port forwarding** (from this Mac only, unless you let other computers on
  the network connect), the clipboard, and dragging files into the VM (with the guest tools).
- **The `vmpane` command**: start, stop, snapshot, run commands, copy files and forward ports from a terminal.
  See [`vmpane` commands](cli.md).
- **Import from Parallels**: turn a Parallels Linux or Windows VM into a VMPane VM.

## AI agents

Claude Code, Codex, Gemini or any MCP client starts `vmpane mcp` and talks to it over stdin and stdout; nothing
listens on the network. Every VM starts at **Off**: agents cannot even see it until you open it to them, at one
of four levels from **Look only** to **Full control** (in the VM's Settings). VMPane asks before an agent runs a command (Deny is the
default), snapshots the VM before an agent's first change, records every call, and one switch stops every agent.
See [VMPane for AI agents](mcp.md) and the [Security model](security-model.md).

## Limits

- **Arm guests only.** No x86 or x86-64 systems: there is no emulation.
- **Windows 11 on Arm** has a 2D display (no DirectX or GPU acceleration) and no Hyper-V, WSL2 or other nested
  virtualization inside it. The Windows licence is yours: VMPane installs from your ISO.
- **macOS guests**: Apple allows two macOS VMs running at once per Mac. See [macOS guests](guides/macos.md).
- **No USB passthrough** in 1.0.
- **Memory comes from your Mac.** A VM uses up to the memory set in its settings. On a Mac out of memory, VMs
  slow down and can crash (Linux guests were seen to fail with memory that changed under them), so VMPane asks
  before starting a VM that needs more than the Mac has available, and a VM's window warns while the Mac is almost
  out. Quit apps you don't need, or give the VM less memory.

## Where to go next

- [Install VMPane](install.md)
- A guide for your guest: [macOS](guides/macos.md), [Linux](guides/linux.md) or [Windows](guides/windows.md)
- [VMPane for AI agents](mcp.md)
