# Security model

This page covers Windows VMs (QEMU), Phase 05. Other parts (control sockets, MCP policy, guest agent) are
added with their phases.

## Threat: a hostile Windows guest

A guest controls every device QEMU emulates for it, so we assume a guest can take over the QEMU process.
What it can reach then:

| process | runs as | sandbox | can reach |
|---|---|---|---|
| `qemu-system-aarch64` | the user | `VMPaneQEMU/Sandbox/qemu.sb` (deny by default) | its VM bundle and run directory (read/write), the QEMU runtime copy (read), HVF, CoreAudio output, outbound network (slirp NAT), listening sockets for the VM's port forwards |
| `swtpm` | the user | `VMPaneQEMU/Sandbox/swtpm.sb` | its VM bundle and run directory; no network, no hypervisor |
| helper (`VMPaneVM`) | the user | none (v2 hardening item) | everything the user can |

- QEMU is built HVF-only with a device allowlist (`qemu/SECURITY-DEVICES.md`): no TCG, no VNC, no
  remote block drivers. Its only entitlement is the hypervisor; library validation stays on (every
  library is signed with our Team ID).
- Every byte from QEMU reaching the helper is untrusted: QMP lines are capped at 1 MiB, decoded strictly
  (a violation closes the connection), and unread events are bounded; `screendump` files are read with
  `O_NOFOLLOW`, size-capped and parsed strictly (P6, 8-bit, at most 8192×8192).
- Nothing from the config reaches a QEMU option string unescaped: paths and values have `,` doubled,
  the VM's name never reaches QEMU, and port forwards (also changed live through HMP) are built only from
  validated parts (IPv4 literal, ports 1–65535, `tcp`/`udp`).
- QEMU's sockets (QMP, SPICE, TPM, guest agent) live in the 0700 run directory; SPICE has no TCP
  listener and no ticket, so the directory's permissions are its access control.
- The children are recorded in `run/<sid>.children` before they run and hold the bundle lock, so no second
  QEMU can open the same disks, and a helper that dies has its children reaped by the next launch.

## Accepted risks (v1)

- **SPICE parsing in the unsandboxed helper.** The SPICE client (spice-glib, C, LGPL) decodes what the
  guest-controlled QEMU sends, inside the helper. Mitigation: QEMU never streams video
  (`streaming-video=off`), no GStreamer plugins are shipped or loaded. Sandboxing the helper is a v2 item.
- **TPM state is not encrypted by VMPane.** The swtpm state (`current/aux/tpm/`, files 0600) is protected
  by FileVault like the disks. A per-VM key in the keychain would turn a lost key (another Mac, a Finder
  copy, an export) into a BitLocker recovery prompt; whoever can copy the bundle can already read the
  disk. swtpm's `--key fd=` is the hook for a later "encrypted VM" option.
- **Port forwards to `0.0.0.0`** expose the guest service on the network, as the user asked; the QEMU
  sandbox allows listening on any local address.
- **Saved RAM state** (`current/state/state.qemu`, snapshots) is a plain file, like the disks.
