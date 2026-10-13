# VMPane

A native macOS app for running virtual machines on Apple silicon:

- **macOS and Linux** guests on Apple's Virtualization.framework
- **Windows 11 ARM** on QEMU with Hypervisor.framework, a software TPM and Secure Boot
- a `vmpane` command-line tool and a built-in **MCP server** (`vmpane mcp`) so AI coding agents can drive VMs
- snapshots as undo, port forwarding and shared folders

Status: public beta ([1.0.0-beta.1](https://github.com/nhtera/vmpane/releases/tag/v1.0.0-beta.1)). Requires macOS 15 or
later on Apple silicon.

## Install

Download the notarized DMG from [GitHub Releases](https://github.com/nhtera/vmpane/releases) (with `SHA256SUMS`
and the GPL corresponding source of the bundled QEMU), or install it with Homebrew:

```sh
brew install --cask nhtera/tap/vmpane
```

VMPane updates itself (Sparkle) and asks before installing an update.

## Limits

- **ARM guests only.** No x86 or x86-64 operating systems (no emulation).
- **Windows 11 ARM**: 2D display only (no DirectX or GPU acceleration); no Hyper-V, WSL2 or other nested
  virtualization inside it. The Windows licence is yours: VMPane installs from your ISO.
- **macOS guests** install from an Apple restore image (IPSW); Apple allows two macOS VMs running at once per Mac.
- **No USB passthrough** in 1.0.
- AI agents act only on VMs you open to them (every VM starts at **Off**), within the level you choose. See
  [docs/mcp.md](docs/mcp.md) and [docs/security-model.md](docs/security-model.md).

## Documentation

The docs are at [vmpane.erai.dev/docs](https://vmpane.erai.dev/docs) (from [docs/](docs/README.md)):
[Install](docs/install.md) · [`vmpane` commands](docs/cli.md) · [VMPane for AI agents](docs/mcp.md) ·
[Security model](docs/security-model.md) · [Releasing](docs/release.md) · [Security policy](SECURITY.md)

## Building

```sh
scripts/bootstrap.sh   # tools (Homebrew bundle, pinned Rust toolchain), generates the Xcode project
scripts/lint.sh
scripts/test.sh
scripts/build.sh Debug
```

See [docs/development.md](docs/development.md) for details.

## Licence

Apache-2.0. See [LICENSE](LICENSE), [NOTICE](NOTICE) and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
