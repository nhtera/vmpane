# Control protocol

How the app, the `vmpane` CLI and the MCP server talk to a running VM's helper. This file is the
contract: `ControlContractTests` fails when the tables below and the code (`ControlMethod`,
`ControlNotification`, `ControlMethodPolicy`) disagree. Later features use these names only.

## Transport

- JSON-RPC 2.0, one message per line (NDJSON), over the helper's Unix socket
  `~/Library/Application Support/VMPane/run/<sid>.sock` (`sid` = first 8 hex digits of the VM id).
- Request lines are at most 1 MiB; a longer line gets an `invalidRequest` error and the connection is
  closed. Responses and notifications may be up to 64 MiB (screenshots). Batches are rejected. Ids are
  integers or strings (`null` is refused); `params` is an object or an array.
- A client that half-closes after sending (`echo … | nc -U`) still gets its responses; a client that stops
  reading for 10 s is disconnected.
- The run directory is 0700 and the socket 0600. The helper checks every peer's uid
  (`LOCAL_PEERCRED`) and reads its audit token (`LOCAL_PEERTOKEN`) for code-signing checks.
- Debugging: `echo '{"jsonrpc":"2.0","id":1,"method":"vm.info"}' | nc -U <socket>`.

## Versioning

`helper.hello {proto, minProto, client}` opens a session; both sides use the highest version they share.
Version 1 is the floor for all of VMPane 1.x, so an older helper keeps working with a newer app or CLI.
No shared version → `protoUnsupported`.

## Methods

Min level is checked against the VM's MCP policy for automated clients (non-interactive CLI, MCP):
`off < observe < control < exec < admin`. `any` includes `off`; `uiOnly` is the app alone. The app is
exempt from levels; an interactive CLI session holding the app's one-time grant (`operator`) is decided
at `admin` and is still refused `uiOnly` methods. Unlisted methods and unknown discriminator values are
denied.

<!-- contract:methods:begin -->
| method | params | result | min level |
|---|---|---|---|
| `helper.hello` | `{proto, minProto, client: {name, version, kind: ui\|cli\|mcp, sessionId?}}` | `{proto, helperVersion, runtimeVersion}` | any |
| `helper.shutdown` | — | `{}` | admin |
| `vm.info` | — | `{id, name, os, backend, state, allowedRequests, capabilities}` | observe |
| `vm.start` | `{headless}` | `{state}` | control |
| `vm.pause` | — | `{state}` | control |
| `vm.resume` | — | `{state}` | control |
| `vm.suspend` | — | `{state}` | control |
| `vm.stop` | `{mode: graceful\|force}` | `{state}` | admin |
| `vm.snapshot.list` | — | `[SnapshotMeta]` | observe |
| `vm.snapshot.create` | `{name, kind: live\|disk, origin}` | `SnapshotMeta` | control |
| `vm.snapshot.restore` | `{id}` | `{generationId}` | control |
| `vm.snapshot.delete` | `{id}` | `{}` | admin |
| `vm.screenshot` | `{maxEdge, format}` | `{dataB64, width, height}` | observe |
| `vm.input.key` | `{usage, down}` | `{}` | control |
| `vm.input.text` | `{text}` | `{}` | control |
| `vm.input.pointer` | `{x, y, buttons}` | `{}` | control |
| `vm.input.scroll` | `{dx, dy}` | `{}` | control |
| `vm.display.show` | — | `{}` | control |
| `vm.display.resize` | `{widthPx, heightPx}` | `{}` | control |
| `vm.settings.get` | — | `config` | observe |
| `vm.settings.apply` | `{patch}` | per field `applied\|nextBoot\|rejected` | admin; sensitive patch: uiOnly |
| `vm.ports.list` | — | rules with resolved guest IP and bind status | observe |
| `vm.clipboard.read` | `{types}` | `{items}` | control + clipboard.allowWithAgents |
| `vm.clipboard.write` | `{items}` | `{}` | control + clipboard.allowWithAgents |
| `agent.status` | — | `{connected, version, os}` | observe |
| `agent.exec` | `{argv, as, cwd, env, timeoutMs, stdin}` | `{execId}` | exec (as:user), admin (as:admin) |
| `agent.exec.input` | `{execId, dataB64, eof}` | `{}` | exec |
| `agent.exec.signal` | `{execId, signal}` (own exec only) | `{}` | exec |
| `agent.file.push` | `{hostPath, guestPath}` | `{bytes}` | exec |
| `agent.file.pull` | `{guestPath, hostPath}` | `{bytes}` | exec |
| `mcp.policy.get` | — | `{policy, confirmExec, autoSnapshot, auditTypedText}` | uiOnly |
| `mcp.policy.set` | `{policy, …}` | `{}` | uiOnly |
| `mcp.enableAll` | — | `{}` | uiOnly |
| `mcp.disableAll` | `{until}` | `{}` | any |
| `events.subscribe` | `{topics}` | `{}` | observe |
| `library.list` | — | VMs (non-UI clients see only VMs at observe or above) | any |
| `vm.create` | `{name, os, …}` | `{id}` | uiOnly |
| `vm.clone` | `{id, name}` | `{id}` | uiOnly |
| `vm.delete` | `{id}` | `{}` | uiOnly |
| `vm.import` | `{path}` | `{id}` | uiOnly |
<!-- contract:methods:end -->

`vm.settings.apply` is uiOnly when its patch touches `mcp`, `clipboard`, `shares`, `agent` or `windows`, or
contains a port rule whose host address is not loopback (`127.0.0.1`, `::1`, `localhost`): any other address
exposes the guest beyond this Mac. `library.*` and `vm.create/clone/delete/import`
run in Core directly (no helper needed) through `LibraryOps`, behind the same policy check.

## Notifications

Sent to clients subscribed (`events.subscribe`) to the topic.

<!-- contract:notifications:begin -->
| notification | params |
|---|---|
| `vm.stateChanged` | `{state, reason}` |
| `agent.connectionChanged` | `{connected}` |
| `exec.output` | `{execId, stream, dataB64}` |
| `exec.exited` | `{execId, code, signal}` |
| `console.output` | `{dataB64}` |
| `snapshot.progress` | `{id, percent}` |
| `install.progress` | `{phase, percent, message}` |
<!-- contract:notifications:end -->

## Errors

JSON-RPC's standard codes (-32700 parse error, -32600 invalid request, -32601 method not found,
-32602 invalid params, -32603 internal error) plus:

| code | name | meaning |
|---|---|---|
| -32010 | backendUnavailable | no backend for this VM on this Mac |
| -32011 | invalidState | not allowed in the VM's current state |
| -32012 | policyDenied | the VM's MCP policy does not allow it |
| -32013 | agentUnavailable | the guest agent is not connected |
| -32014 | busy | another operation is running |
| -32015 | unsupportedLive | needs the VM stopped |
| -32016 | insufficientSpace | not enough free disk space for RAM state |
| -32017 | protoUnsupported | no shared protocol version |
