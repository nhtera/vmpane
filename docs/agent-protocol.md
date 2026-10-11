# Guest agent protocol

`vmpane-agent` runs inside the guest as root (Linux, macOS) or LocalSystem (Windows) and dials the host. The
helper (`VMPaneVM`) accepts at most one agent connection per VM and serves the `agent.*` control methods over
it ([control protocol](control-protocol.md)).

The Rust types in `agent/crates/vmpane-agent-proto` are the schema source. `agent/proto/schema/protocol.json`
(methods, directions, caps, JSON Schemas, limits, error codes) and the test vectors in `agent/proto/vectors`
are generated from them:

```
cd agent && cargo test -p vmpane-agent-proto -- --ignored regen
```

A normal `cargo test` fails when the committed files are stale. The host's Swift codec
(`VMPaneControl/Agent`) is tested against the same vectors.

**The host treats every byte from the guest as untrusted.**

## Transports

The agent tries these in order on every (re)connect. Its backoff is 1 s, doubling to 30 s, and back to 1 s
after a connection that lasted 10 s.

| guest | transport | host end |
|---|---|---|
| Linux, macOS on VZ | vsock CID 2, port 6271 | `VZVirtioSocketListener` on the VM's socket device |
| Windows on QEMU | virtio-serial port `app.vmpane.agent.0` | `run/<sid>/agent.sock` (QEMU listens, the helper connects while the VM runs and no Windows install uses the port) |
| fallback | TCP: QEMU `10.0.2.200:6271` (slirp `guestfwd`), VZ NAT gateway `:6271` | never on the host's own network; `hello.token` required |

`vmpane-agent --connect unix:<path>` dials a Unix socket instead (tests).

## Frames

```
u32 BE length | u8 type | payload          length = 1 + payload length
```

| type | payload | limit |
|---|---|---|
| 0 message | one JSON-RPC 2.0 object, UTF-8 | 1 MiB |
| 1 chunk | `u32 BE stream id` + 1 or more bytes | 256 KiB of data |
| 2 end | `u32 BE stream id` + `u8 status` (0 ok, 1 error, 2 cancelled) | — |

A frame whose header breaks a limit is rejected before its payload is read. JSON nesting is limited to 32 levels.
Nesting is checked on the raw bytes, before parsing. Strings and object keys are limited to 64 KiB each.
Larger data travels on streams.

## Streams

Stream ids are never 0. The side that names a stream in a request or a result allocates its id: the host uses
odd ids, the guest even ones. Data flows from the frame's sender. At most 16 streams are open on a connection,
both directions together.

A response that names a stream is always sent before the stream's first chunk. The host registers the streams
in a response before it reads further, so data that follows at once is never "unknown".

The host stops reading the socket while one stream holds more than 4 MiB nobody has consumed. That pushes back
on the guest through the transport.

## Handshake

The guest speaks first, with `hello`:

```json
{"jsonrpc":"2.0","id":1,"method":"hello","params":{"proto":1,"minProto":1,"agentVersion":"0.1.0","os":"linux",
 "arch":"aarch64","osVersion":"Ubuntu 24.04.3 LTS","caps":["exec","file","time","power","net","ports","freeze"],
 "session":false,"token":null}}
```

The host answers `{proto, hostVersion}` with the highest version in both `[minProto, proto]` ranges. Without
an overlap it answers error `protoUnsupported` (-32017, `data: {proto, minProto}`) and closes. The agent then
retries every 5 minutes; a guest-tools update fixes it. The floor stays `proto` 1 for all of v1.x, so older
agents keep working with newer hosts.

Nothing else is accepted before `hello`. On TCP, a wrong or missing token gets `unauthorized` and the host
closes. The host then sets the guest clock (`time.set`); it does the same after a resume.

## Methods

Host → guest requests unless noted. A method whose cap the agent did not advertise answers `capUnsupported`.

| method | cap | params → result |
|---|---|---|
| `agent.info`, `agent.ping` | — | `{}` → info / `{}` |
| `exec.start` | exec | `{argv \| shell, env, cwd, as: user\|admin, stdin, timeoutMs}` → `{execId, stdout, stderr, stdin?}` (guest streams) |
| `exec.signal` | exec | `{execId, signal: int\|term\|kill}` → `{}` |
| `exec.exited` (guest → host) | — | `{execId, code, signal, timedOut}`, after both output streams ended |
| `file.push` | file | `{path, size, sha256, stream, mode, overwrite}` + host stream → `{size, sha256}` once the stream ended |
| `file.pull` | file | `{path, maxBytes}` → `{size, stream}` (guest stream of exactly `size` bytes) |
| `file.stat` / `file.mkdirTemp` | file | `{path}` → `{kind, size, mode, mtimeUnixNanos}` / `{prefix}` → `{path}` |
| `session.reveal` | reveal | `{path}` → `{}`: selects it in Finder / Explorer / the file manager (user-session helper) |
| `clipboard.get` / `clipboard.set` | clipboard | `{types}` → `{items}` / `{items}` → `{}`: text and PNG on streams (≤ 32 MiB), file lists inline; macOS guests (user-session helper) |
| `display.set` | display | not implemented yet (Windows display path C) |
| `clipboard.changed` (guest → host) | — | `{types, seq}`, at most 10/s |
| `time.set` | time | `{unixNanos}` → `{}` |
| `power.shutdown` | power | `{reboot, force}` → `{}` (answered first) |
| `net.addrs`, `ports.listening` | net, ports | → interfaces / listening sockets (hints only) |
| `fs.freeze`, `fs.thaw` | freeze | `{timeoutMs ≤ 60000}` → `{frozen}` / → `{thawed}` |
| `agent.heartbeat` (guest → host) | — | `{}` every 5 s |

Notes on individual methods:

- **`exec.start`:** `as: "admin"` runs in the daemon. `as: "user"` runs in the logged-in user's session helper
  and answers `noSession` without one. The process leads its own process group, so a timeout, a signal or a
  disconnect kills the whole tree.
- **`file.push`:** writes a hidden temporary file beside the target. It checks size and SHA-256, syncs, then
  renames the file into place.
- **`fs.freeze`:** freezes Linux file systems with `FIFREEZE`. They always thaw: on `fs.thaw`, on the timeout
  (default 10 s), or when the host disconnects. macOS only syncs, which is no consistency point, so it reports
  nothing frozen. The helper takes a disk snapshot of a running VM only when something was frozen.
- **`agent.heartbeat`:** after a VZ snapshot restore the guest's vsock socket survives while the host's is gone.
  Only a write notices that, so the agent writes every 5 s.

Errors are JSON-RPC's standard codes, plus:

| code | name | code | name |
|---|---|---|---|
| -32017 | protoUnsupported | -32045 | timeout |
| -32040 | helloRequired | -32046 | tooLarge |
| -32041 | capUnsupported | -32047 | busy |
| -32042 | notFound | -32048 | noSession |
| -32043 | permissionDenied | -32049 | integrity |
| -32044 | ioError | -32050 | unauthorized |

## User-session helper

`vmpane-agent session` (the same binary) runs in each user session. It is started by:
- Linux: the global systemd user unit `vmpane-session.service`;
- macOS: a LaunchAgent;
- Windows: the service, in the console session.

It dials the daemon's socket (`/run/vmpane-agent.sock`, `/var/run/vmpane-agent.sock` on macOS) and speaks
this same protocol, with the daemon in the host's role.

The daemon relays to the current helper, mapping exec and stream ids both ways:
- `exec.start {as: "user"}` and its `exec.signal`, stdin and output;
- `session.reveal`;
- `clipboard.get` / `clipboard.set` with their streams (macOS);
- the helper's `clipboard.changed`, which goes on to the host. The helper polls the pasteboard every 250 ms and
  does not report its own `clipboard.set`.

Without a helper these answer `noSession`. The `session` flag in `agent.info` says whether a helper is
connected now.

The socket is world-writable. Who may stay:
- the peer's uid must own the active console session: logind's foreground seat session on Linux (any active
  session on a guest without seats), the owner of `/dev/console` on macOS;
- the helper must be the daemon's own version. On a mismatch, after a guest-tools update, the daemon refuses
  its `hello`, the helper exits 0, and its service manager starts the installed binary.

## Violations

Each of these makes the host close the connection:
- a bad frame or message, or a limit broken;
- a request from the guest other than `hello`;
- a notification not listed above;
- a response to no request;
- data on a stream no response named;
- `clipboard.changed` faster than 10/s.

The helper then refuses agent connections for 1 s, doubling to 60 s after repeated violations.

A request the host abandoned on its timeout gets its late answer ignored, and the data of any streams that
answer named is dropped.

## Delivery

- **Linux:** `guest-tools/build-linux.sh` stages the static aarch64 musl binary, `install.sh`, the systemd unit
  and `SHA256SUMS`. The app carries them in `Contents/Resources/GuestTools/linux` and the helper's runtime copy
  in `GuestTools/linux`. VZ shares that directory read-only as the virtiofs tag `vmpane-tools`. To install or
  update:

  ```
  sudo mount -t virtiofs vmpane-tools /mnt/vmpane-tools && sudo /mnt/vmpane-tools/install.sh
  ```
- **macOS:** `guest-tools/build-macos.sh` builds `VMPane Agent.pkg`. It installs the binary in
  `/Library/Application Support/VMPane/Agent`, the LaunchDaemon `app.vmpane.agent` and the LaunchAgent
  `app.vmpane.session` (Aqua sessions). Signing:
  - the binary with `VMPANE_SIGN_IDENTITY` (hardened runtime);
  - the package with `VMPANE_INSTALLER_IDENTITY` (Developer ID Installer);
  - notarized with `VMPANE_NOTARIZE=1`.

  macOS guests find it at `/Volumes/My Shared Files/vmpane-tools`.
- **Windows:** the agent ships as an MSI on the guest-tools ISO.

## Testing

| what | command |
|---|---|
| unit and stand-in-host tests | `cd agent && cargo test --workspace` |
| Swift codec and connection (incl. against the built agent) | `scripts/test.sh --swift-only --filter 'Agent\|Vector\|Randomized'` |
| real Linux guest | `scripts/itest.sh agent-linux` |
| fuzz smoke, nightly | `scripts/fuzz.sh [seconds]` |
