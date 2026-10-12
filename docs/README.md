# VMPane documentation

How to install VMPane, run macOS, Linux and Windows virtual machines on your Mac, and let AI agents use them
safely. These pages are also the docs at [vmpane.erai.dev/docs](https://vmpane.erai.dev/docs): the tables below
are the site's navigation, in order. A file not listed here is not published.

## Get started

| Page | Contents |
|---|---|
| [Overview](overview.md) | What VMPane is, the three guests, AI agents and the limits |
| [Install](install.md) | Requirements, the DMG or Homebrew, updates and uninstalling |

## Guests

| Page | Contents |
|---|---|
| [macOS guests](guides/macos.md) | Apple's restore image, the install, guest tools, snapshots |
| [Linux guests](guides/linux.md) | Ubuntu, Debian and Fedora from the catalog, your own arm64 ISO, shared folders |
| [Windows guests](guides/windows.md) | Windows 11 on Arm from your ISO, set up with no clicks |

## AI agents

| Page | Contents |
|---|---|
| [VMPane for AI agents](mcp.md) | Connect Claude Code, Codex or Gemini; the five access levels; the tools |
| [`vmpane` commands](cli.md) | Every command of the `vmpane` tool |

## Reference

| Page | Contents |
|---|---|
| [Security model](security-model.md) | What a VM, an agent and the app can and cannot reach |
| [VM bundle format](bundle-format.md) | What is inside a `.vmpane` bundle |
| [Architecture](architecture.md) | How the app, the helpers and the guest tools fit together |

## Project

| Page | Contents |
|---|---|
| [Security policy](../SECURITY.md) | How to report a vulnerability |
| [Contributing](../CONTRIBUTING.md) | How to build VMPane and send a change |
| [Code of conduct](../CODE_OF_CONDUCT.md) | How we work together |

## Repository files (not published)

These stay on GitHub: [Releasing](release.md), [release checklist](release-checklist.md),
[development](development.md), [control protocol](control-protocol.md), [agent protocol](agent-protocol.md),
[live capabilities](live-capabilities.md) and the [design decisions](adr/).
