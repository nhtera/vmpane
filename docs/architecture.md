# Architecture

VMPane is a macOS app for Apple silicon that runs macOS, Linux and Windows 11 ARM virtual machines.
This page describes how VMPane is built today. A part not built yet would be marked *planned*; at the moment none is.

## Processes

| process | what it does |
|---|---|
| `VMPane.app` | VM library, creation wizard, settings. Never runs a VM itself. |
| `VMPaneVM.app` (one per running VM) | Owns one VM: its window, Dock tile, control socket and backend. A crash takes down one VM, not the app. |
| `vmpane` CLI | Scripting and the MCP server (`vmpane mcp`). Talks to helpers over their control sockets. |
| `qemu-system-aarch64`, `swtpm` | Child processes of a Windows VM's helper, run under deny-by-default sandbox profiles. |
| guest agent (Rust) | Runs inside the guest, installed with the guest tools: clipboard, exec, file transfer, display resize. Talks to the host over vsock (Linux, macOS) or virtio-serial (Windows). |

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

`Packages/VMPaneSpice` (helper only) is the Windows display: CocoaSpice vendored with our patches
(`scripts/vendor-cocoaspice.sh`), built against `SpiceSDK/` (headers and link stubs of the SPICE client
libraries, generated from the QEMU build by `qemu/scripts/spice-sdk.sh`; CI fails on drift).

## App bundle

```
VMPane.app/Contents/
  MacOS/VMPane                     main app
  Helpers/vmpane                   CLI (not in MacOS/: `vmpane` and `VMPane` are the same name on case-insensitive APFS)
  Helpers/VMPaneVM.app             per-VM helper
  Helpers/VMPaneVM.app/Contents/Frameworks/   SPICE client libraries (weak-linked; from the QEMU bundle)
  Helpers/qemu/{bin,lib}/          QEMU, qemu-img, swtpm and their libraries
  Resources/qemu/share/            firmware and QEMU data files, passed with -L
  Resources/qemu/MANIFEST.json     the QEMU bundle's identity (part of the runtime copy's name)
```

Every Mach-O is listed in `Config/signing-manifest.json` with its signing identifier and entitlements;
`scripts/sign.sh` signs inside-out from it and `--verify` checks a built bundle against it.

## Trust between processes

Helpers accept control connections only from peers whose code signature satisfies our designated
requirement (checked from the socket's audit token, not the PID). A Windows VM's isolation and accepted
risks are in [security-model.md](security-model.md).

## QEMU (Windows guests)

A Windows VM's helper runs QEMU from its runtime copy (`runtime/<version>/qemu`; a helper started from the
app bundle makes the copy itself):

1. **Firmware.** The shipped EDK2 code is padded to the 64 MiB flash in `run/<sid>/` at each start; the
   VM's variables (`current/aux/efi_vars.fd`) are made once from the Secure Boot template.
2. **swtpm**, then **QEMU**, each through `sandbox-exec` with its profile (`VMPaneQEMU/Sandbox/*.sb`),
   recorded in `run/<sid>.children` before it runs (by pid and start time: the launcher execs), holding
   the bundle lock, with a minimal environment and `TMPDIR` in the run directory. Paths handed to them
   are real paths (sandbox rules match those).
3. **QMP** (`run/<sid>/qmp.sock`) controls QEMU: pause, ACPI power button, quit, screenshots
   (`screendump`, PPM), input (`input-send-event`), RAM state (file migration), port forwards
   (`hostfwd_add`/`hostfwd_remove`). Its events drive the state machine; an unexpected exit, or the TPM
   going away, is a failure carrying the end of `logs/qemu.log`.
4. **Display**: the helper's SPICE client on `run/<sid>/spice.sock`, reconnected whenever QEMU restarts.
   QEMU runs with `-no-shutdown`: a guest power-off pauses it, the client disconnects, then QEMU quits
   (QEMU's spice-server can hang in its cleanup with a client still connected).
5. **Disk space**: NVMe has no write-error policy, so the helper pauses the guest when the bundle's
   volume drops below 2 GiB free and resumes it only from 3 GiB (`diskFull` event).

Suspend and live snapshots save RAM state with a plain file migration after `stop` (`state/state.qemu`,
with `state-qemu.json` naming the QEMU that wrote it: only the same QEMU loads it); the swtpm state travels
in the stream. Unlike VZ's, QEMU's saved state does not need an unlocked Mac.
