# VMPane

A native macOS app for running virtual machines on Apple silicon:

- **macOS and Linux** guests on Apple's Virtualization.framework
- **Windows 11 ARM** on QEMU with Hypervisor.framework, a software TPM and Secure Boot
- a `vmpane` command-line tool and a built-in **MCP server** (`vmpane mcp`) so AI coding agents can drive VMs
- snapshots as undo, port forwarding and shared folders

Status: early development (pre-alpha). Requires macOS 15 or later on Apple silicon.

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
