# Live capabilities (S11)

Which settings change while a guest runs, on each backend. `vm.settings.apply` follows this table: the
setting kind in `SettingsPatch.kind(of:)` and the backend's `applyLive` must agree with it. The settings
UI shows the same split (Apply now / Next start).

## Virtualization.framework

Measured 2026-10-10 on an Apple M4 Pro, macOS 15.7.3 (24G419), with Ubuntu 24.04 and macOS 15.6.1 guests:
`scripts/itest.sh vz-live-probe` (helper hook `VMPANE_TEST_PROBE_LIVE`). "Live" means the API call
succeeded and the guest kept running (Linux: serial ticks continue; macOS: the display still draws).

| change | API | Linux guest | macOS guest | VMPane setting | VMPane mode |
|---|---|---|---|---|---|
| unplug / replug a NIC | `VZNetworkDevice.attachment = nil` / NAT | live | live | `network.N.mode` nat ⇄ none | live for NICs the VM booted with; adding/removing NICs or MAC changes: next start |
| virtiofs share set | `VZVirtioFileSystemDevice.share` replace | live | live | `shares` | live when the VM booted with at least one share (the share device exists); else next start |
| display size | `VZGraphicsDisplay.reconfigure(sizeInPixels:)` | live | live | `display.widthPx/heightPx` | live |
| display follows window | `VZVirtualMachineView.automaticallyReconfiguresDisplay` | view setting | view setting | `display.autoResize` | live |
| USB mass storage | `VZUSBController.attach/detach` (macOS 15) | live | live | `removable` (later) | next start in v1; every VZ VM gets an XHCI controller so hot-plug can follow |
| memory balloon target | `targetVirtualMachineMemorySize` | live | live | none (memory pressure feature later) | not a setting |
| memory size | — | restart | restart | `memory.mib` | next start |
| CPU count | — | restart | restart | `cpu.count` | next start |
| audio streams | no API after creation | impossible | impossible | `audio.*` | next start |
| Rosetta, nested virt | configuration only | restart | restart | `vz.*` | next start |

Verified inside a Linux guest (itest `vz-devices`): a share added live appears in the `vmpane-shares` mount,
both on a mount kept since boot and on a fresh one. Not yet verified from inside the guest (needs the
agent, Phase 07): the network lease after a replug, memory freed for the balloon, and macOS guests'
view of replaced shares.

Host-side settings (`name`, `portForwards`, `mcp`, `ui`, `clipboard.allowWithAgents`) apply as soon as
they are saved; the rest of `clipboard` (`mode`, `keepFormatting`) at the next start. Identity, disks, platform and the install source are never changed through settings.

## Saved state and the locked Mac

Virtualization encrypts saved VM memory (`.vzvmsave`) with a Secure Enclave key that works only while the
Mac is unlocked. Saving (suspend, live snapshot) works while locked; restoring fails ("permission
denied"). The helper keeps the state and answers `macLocked` (-32018) instead of cold-booting, so a
suspended VM is never lost to a locked screen. Integration tests that restore skip on a locked Mac.

## QEMU

| change while running | how |
|---|---|
| port forwards (`portForwards`) | slirp `hostfwd_remove` / `hostfwd_add` on the first NAT NIC |
| everything else (CPU, memory, disks, removable media, NICs, display size, audio, GPU, TPM) | next start |

Display resize follows the window through SPICE once spice-vdagent runs in the guest (Phase 06);
removable media changes come with the Windows install work (Phase 06).
