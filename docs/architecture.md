# Architecture

VMPane is a macOS app for Apple silicon that runs macOS, Linux and Windows 11 ARM virtual machines.
This page describes the intended shape; parts not built yet are marked *planned*.

## Processes

| process | what it does |
|---|---|
| `VMPane.app` | VM library, creation wizard, settings. Never runs a VM itself. |
| `VMPaneVM.app` (one per running VM) | Owns one VM: its window, Dock tile, control socket and backend. A crash takes down one VM, not the app. |
| `vmpane` CLI | Scripting and the MCP server (`vmpane mcp`). Talks to helpers over their control sockets. |
| `qemu-system-aarch64`, `swtpm` (*planned*) | Child processes of a Windows VM's helper, run under a deny-by-default sandbox profile. |
| guest agent (Rust, *planned*) | Runs inside the guest: clipboard, exec, file transfer, display resize. Talks to the host over vsock (Linux, macOS) or virtio-serial (Windows). |

## Backends

- **Virtualization.framework** for macOS and Linux guests (`VMPaneVZ`). VZ objects live on one serial
  queue owned by an actor, see [ADR 0003](adr/0003-swift6-vz-isolation.md).
- **QEMU + Hypervisor.framework** for Windows 11 ARM (`VMPaneQEMU`): our own EDK2 build with Secure
  Boot and Microsoft keys, `swtpm` for TPM 2.0, display over SPICE ([ADR 0001](adr/0001-display-path.md)).

### Backend contract (`VMBackend`, VMPaneCore)

The helper drives every backend the same way; a new backend implements exactly this:

- **State comes from events.** `events` (one consumer) reports `started`, `paused`, `resumed`,
  `suspended`, `stopped(reason)`, `failed`, `installProgress`, `consoleOutput`. Requests only start work;
  the helper's state machine moves on events. A guest that powers off by itself sends `stopped`.
- **`start(StartOptions)`** rebuilds the devices from `options.config` (the saved config: next-boot
  settings take effect) and either cold boots or, with `stateDirectory`, resumes saved RAM state. A
  restore that cannot read the state *now* throws `SavedStateLocked` (the helper keeps the state);
  any other restore error makes the helper cold boot and delete it.
- **`suspend(to:)`** saves RAM state (`*.partial`, renamed when complete) and stops; on failure the VM
  is running again. **`saveState(to:)`** saves the paused VM's state for a live snapshot.
- **`applyLive(config, paths)`** applies settings of kind `live` (`SettingsPatch.kind`) to the running
  VM and returns those now in effect; the rest wait for the next start. Default: none.
- **`screenshot` / `send(InputEvent)`** in guest display pixels (pointer `buttons`: bit 0 left, 1 right,
  2 middle).
- **`capabilities`** (`LiveCapabilities`) gate requests in `vm.info`.
- **Config hooks** (`BackendFactory.Made`): `afterStart` and `afterStop` return config changes the
  helper saves (macOS install recorded; Linux install media detached).
- **Saved-state validity** is `DeviceSet`: the config's guest-visible hardware plus the backend's
  `layoutVersions` entry, bumped whenever a backend builds different devices for the same config.

## Swift packages

All logic that can be unit-tested lives in `Packages/VMPaneKit`; the Xcode targets keep only entry
points, windows and views.

```
VMPaneCore      bundle format, config, storage, snapshots, backend protocol, policy, audit
VMPaneControl   JSON-RPC over Unix sockets, control methods, peer identity, agent framing   -> Core
VMPaneVZ        Virtualization.framework backend                                            -> Core
VMPaneQEMU      QEMU child-process backend                                                  -> Core
VMPaneHost      helper-process logic: agent link, install, networking, import               -> Core, Control, VZ, QEMU
VMPaneMCP       MCP server (hand-rolled, see ADR 0002)                                      -> Core, Control
VMPaneUI        shared SwiftUI views and view models                                        -> Core, Control, Host
```

## App bundle

```
VMPane.app/Contents/
  MacOS/VMPane                     main app
  Helpers/vmpane                   CLI (not in MacOS/: `vmpane` and `VMPane` are the same name on case-insensitive APFS)
  Helpers/VMPaneVM.app             per-VM helper
  Helpers/qemu/{bin,lib}/          QEMU, qemu-img, swtpm and their libraries (planned)
  Resources/qemu/share/            firmware and QEMU data files, passed with -L (planned)
```

Every Mach-O is listed in `Config/signing-manifest.json` with its signing identifier and entitlements;
`scripts/sign.sh` signs inside-out from it and `--verify` checks a built bundle against it.

## Trust between processes

Helpers accept control connections only from peers whose code signature satisfies our designated
requirement (checked from the socket's audit token, not the PID). Secrets such as the TPM state key are
kept in the login keychain with an access list limited to VMPane's own binaries.
