# Security model

This page covers Windows VMs (QEMU, Phase 05) and the agent policy for control sockets (Phase 10). The guest
agent and integration features are covered in `agent-protocol.md` and the phase plans.

## Threat: a hostile Windows guest

A guest controls every device QEMU emulates for it, so we assume a guest can take over the QEMU process.
What it can reach then:

| process | runs as | sandbox | can reach |
|---|---|---|---|
| `qemu-system-aarch64` | the user | `VMPaneQEMU/Sandbox/qemu.sb` (deny by default) | its VM bundle (read; write only `current/`: disks, UEFI variables, saved state) and run directory, the QEMU runtime copy (read), HVF, CoreAudio output, outbound IP (slirp NAT), listening sockets for the VM's port forwards, the host's DNS configuration |
| `swtpm` | the user | `VMPaneQEMU/Sandbox/swtpm.sb` | its VM bundle (read; write only `current/aux/tpm`) and run directory; no network, no hypervisor |
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

## Threat: an AI agent acting through VMPane

The agent policy is a guardrail for AI agents that drive VMs through VMPane's interfaces (MCP, and the `vmpane`
CLI run without a terminal). An agent with a general shell on the Mac is not constrained by it: it could edit
files, sign binaries or drive the app's UI like the user.

- **Who is asking** comes from the control-socket peer's code signature (audit token), never from what it says
  (`PeerClassifier`). A release helper accepts as the app only `app.vmpane.mac` signed with its own Team ID
  and Apple's anchor; `app.vmpane.mac.cli` is the CLI; everything else is an agent. The helper's own window
  runs in the helper's process. Development (ad hoc) builds compare identifiers only, and only they honour the
  integration tests' bridge (`app.vmpane.mac.itest`, built by `scripts/itest.sh`, never shipped).
- **What it may do** is `ControlMethodPolicy`'s table at the VM's level (`off` by default; `observe`,
  `control`, `exec`, `admin`); app-only actions stay app-only. Core-direct library operations (`LibraryOps`)
  use the same table; agents see only VMs at `observe` or above.
- **The level counts only with VMPane's tag**: `mcp.tag` = HMAC-SHA256 over the VM id, the `mcp` settings and
  `clipboard.allowWithAgents`, written when the app changes them. A level raised in `config.json` by hand reads
  as `off`. The key is a 0600 file, `policy.key`, in VMPane's folder: the login keychain is not available to
  helpers started from SSH or on a locked Mac, and an agent able to read the file has a shell anyway. (A
  keychain item with a trusted-application ACL, shown to work in spike S4, can replace it.)
- **Operator**: your own `vmpane` at a terminal acts as `operator` (everything but app-only actions, whatever
  the level) when stdin and stdout are terminals, no ancestor is `vmpane mcp`, and you granted it once
  (`vmpane operator grant`, a tagged `operator.grant` file; `revoke` removes it). The helper believes the
  operator claim only from a peer signed as the CLI. An agent faking a terminal (e.g. `script`) with a grant
  in place passes; that agent has a shell, and every operator call is audited as `operator`.
- **Kill switch**: `vmpane mcp kill`, the menu bar or ⌃⌥⌘. (while VMPane runs), or `mcp.disableAll` from any
  client, writes a tagged `killswitch` file every helper watches (and reads at launch), so it works with no app
  running. While engaged, every non-app call is refused (helpers and Core-direct library operations), agent
  connections close, commands agents started are killed, their file transfers stop, and port forwards agents
  added go down (measured: all within 0.15 s). Only the app releases it. The file is written released when the
  policy key is made; after that a missing or edited file counts as engaged.
- **Audit**: every request a non-app client makes of a VM's helper, every refusal, and every clone or delete
  of the VM by the CLI or an agent is one line in the VM's `logs/mcp-audit.jsonl` (synced before the answer;
  typed text and clipboard contents as SHA-256 unless the VM records typed text, a command's input always as
  SHA-256 and size; 10 MB × 5). Listing the library, creating and importing touch no VM and are not recorded.
  It is a record, not tamper-proof.

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
- **The guest reaches the Mac's loopback services** through slirp's host alias 10.0.2.2 (any service that
  listens on 127.0.0.1, as for every slirp/NAT VM). A later option is slirp's `restrict` mode with only the
  agent's forward.
- **Integration-test hooks** (`VMPANE_TEST_*` environment variables) exist in release helpers; they are
  read from the helper's own environment only.
