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
  reading for 10 s is disconnected. Input from an agent (typing, a batch, a held key) stops once its client
  closes its side, half-closed or gone: the answer says so ("the client closed its connection").
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

In `helper.hello`, `sessionId` names an agent session (one `vmpane mcp` process: its undo snapshot and audit
lines), and `client.operator: true` says the CLI passed its operator checks; the helper honours it only from a
peer signed as VMPane's CLI. `agent.exec`'s `input` (UTF-8 text, at most 64 KiB) is the command's whole stdin, fed
with end-of-file after it starts; when the VM asks before agents run commands, the question shows it, and
`stdin: true` (streaming with `agent.exec.input`) is refused to agents.

<!-- contract:methods:begin -->
| method | params | result | min level |
|---|---|---|---|
| `helper.hello` | `{proto, minProto, client: {name, version, kind: ui\|cli\|mcp, operator?}, sessionId?}` | `{proto, helperVersion, runtimeVersion}` | any |
| `helper.shutdown` | — | `{}` | admin |
| `vm.info` | — | `{id, name, os, backend, state, allowedRequests, capabilities, pendingRestart}` | observe |
| `vm.start` | `{headless}` | `{state}` | control |
| `vm.pause` | — | `{state}` | control |
| `vm.resume` | — | `{state}` | control |
| `vm.suspend` | — | `{state, message?}` (`message`: pending hardware settings will discard the state) | control |
| `vm.stop` | `{mode: graceful\|force}` | `{state}` | admin |
| `vm.snapshot.list` | — | `[SnapshotMeta]` | observe |
| `vm.snapshot.create` | `{name, kind: live\|disk, origin}` (disk: VM stopped; live: VM running, paused briefly) | `SnapshotMeta` | control |
| `vm.snapshot.restore` | `{id}` (a running VM is powered off first, then started again) | `{generationId, state, resumed?, message?}` | control |
| `vm.snapshot.delete` | `{id}` | `{}` | admin |
| `vm.snapshot.rename` | `{id, name}` (1-200 characters; an agent session's undo snapshot only by the app) | `{}` | control |
| `vm.screenshot` | `{maxEdge, format}` | `{dataB64, width, height}` | observe |
| `vm.input.key` | `{usage, down}` | `{}` | control |
| `vm.input.text` | `{text}` (an agent's is typed in pieces: a take over or the kill switch stops it at the next one) | `{}` | control |
| `vm.input.pointer` | `{x, y, buttons}` | `{}` | control |
| `vm.input.scroll` | `{dx, dy}` | `{}` | control |
| `vm.input.batch` | `{actions: [{type: key, usages} \| {type: text, text, submit?} \| {type: click, x, y, button?, count?, modifiers?} \| {type: move, x, y} \| {type: drag, from, to} \| {type: scroll, dx, dy} \| {type: wait, ms}], stopOnError?, settleMs?, verify?}` (≤ 50 actions, waits ≤ 30 s together; each action is also decided and audited as the `vm.input.*` request it stands for; a stop ends it between actions, pieces of text and captures) | `{results: [{i, ok, error?}], verified: {status: changed\|unchanged\|unknown, changeRatio, bbox?, settled, waitedMs, reason?}, screen?: {width, height}}` (guest pixels) | control |
| `vm.signIn` | `{}` (only with the VM's `mcp.signIn` on, inside the policy's tag; the guest tools' `session.state` must report `greeter` or `locked`; at exec and admin the person is asked first; a password field must be on the screen once woken; the kept password is typed by the helper itself, never part of a request, reply or log; agents' input answers `busy` meanwhile) | `{verified: {status: signed_in\|already_signed_in}}` once `session.state` reports `unlocked` (within 30 s) | control |
| `vm.agent.activity` | `{}` | `{acting, takenOver, stopped, level, client?, current?, recent: [{method, what, ok, at}]}`: what AI agents do on the VM (acting: a request in the last 10 s; no notification when that runs out, so ask again; `stopped`: VMPane's kill switch is on; `client`: the name the agent gave itself, made printable; `recent`: the last 3, a repeat replacing the newest) | uiOnly |
| `vm.agent.takeOver` | `{}` (the person takes over: agents' requests that change anything, and `vm.clipboard.read`, answer `takenOver`, also after waits; a batch or typing under way stops at its next piece; commands and transfers already running go on; the operator CLI is not held) | the activity | uiOnly |
| `vm.agent.resume` | `{}` | the activity | uiOnly |
| `vm.agent.stop` | `{}` (ends what agents do on this VM: their commands, desktop apps and transfers, and their connections; then holds them as `vm.agent.takeOver` does until `vm.agent.resume`; unlike the kill switch, only this VM) | the activity | uiOnly |
| `vm.screen.read` | `{source?: ocr\|elements\|auto\|both, region?: {x, y, width, height}, maxItems?}` (guest pixels; `ocr` is recognized on the Mac from the display; `elements` needs the guest tools' `screen` cap; `auto`: elements when they have it, else ocr; text cleaned of control and bidi characters, never logged) | `{source, screen: {width, height}, ocr?: {items: [{text, rect: [x, y, w, h]}], truncated}, elements?: {items: [{role, name, value?, rect, enabled?, focused?}], truncated}, elementsError?}` (`elementsError`: why there are no controls, for auto and both; VMPane's words, the guest's message only quoted) | observe |
| `vm.display.show` | — | `{}` | control |
| `vm.install.cancel` | — (ends a Windows install; a running VM is ejected from its install discs and stopped) | `{state}` | uiOnly |
| `vm.settings.get` | — | `config` | observe |
| `vm.settings.apply` | `{patch}` (JSON merge patch over the config) | `{fields: {path: applied\|nextBoot\|rejected}, reasons?}` | admin; sensitive patch: uiOnly |
| `vm.ports.list` | — | `{rules: [{…rule, status: listening\|blocked\|failed\|inactive, reason?}], listening: [{proto, port, process?}]}` (`blocked`: macOS Local Network privacy; `listening`: the guest agent's open ports, as suggestions) | observe |
| `vm.clipboard.read` | `{types?}` (text, png, files; also html and rtf, which an older agent leaves out) | `{items: [{type: text, text} \| {type: html, text} \| {type: rtf, text} \| {type: png, dataB64} \| {type: files, files}]}` (guest agent's clipboard: macOS and Windows guests; `files` are guest paths, for `agent.file.pull`; follows `clipboard.mode`'s direction) | control + clipboard.allowWithAgents |
| `vm.clipboard.write` | `{items: [{type: text, text} \| {type: html, text} \| {type: rtf, text} \| {type: png, dataB64}]}` (html and rtf need guest tools from 1.0.0-beta.11) | `{}` (follows `clipboard.mode`'s direction) | control + clipboard.allowWithAgents |
| `agent.status` | — | `{connected, version, os, osVersion, proto, caps, session, outdated}` (`outdated`: older than the helper's VMPane) | observe |
| `agent.exec` | `{argv, as, cwd, env, timeoutMs, stdin, input, desktop?}` (`desktop: true`: opens it on the signed-in user's desktop, as the user, without stdin or a timeout; needs the guest tools' `desktop` cap) | `{execId}`; with `desktop`: `{execId, pid, launched: true}` at once (no output; `exec.exited` when it ends) | exec (as:user), admin (as:admin) |
| `agent.exec.input` | `{execId, dataB64, eof}` | `{}` | exec |
| `agent.exec.signal` | `{execId, signal}` (own exec only) | `{}` | exec |
| `agent.file.push` | `{hostPath, guestPath, overwrite}` | `{bytes}` | exec |
| `agent.file.pull` | `{guestPath, hostPath, overwrite}` | `{bytes}` | exec |
| `vm.files.drop` | `{paths}` (host files and folders, e.g. dropped on the VM window) | `{guestPath, files, bytes, skipped, revealed}`: copied into a new folder in the logged-in user's `Desktop/VMPane Drops`, owned by that user, then shown | exec |
| `vm.files.cancel` | — | `{}`: stops the running `vm.files.drop` this connection started (it fails with "cancelled"; the partial drop folder is removed) | exec |
| `mcp.enableAll` | — | `{}` | uiOnly |
| `mcp.disableAll` | `{until}` | `{}` | any |
| `events.subscribe` | `{topics}` | `{}` | observe |
| `library.list` | — | VMs (non-UI clients see only VMs at observe or above) | any |
| `vm.create` | `{name, os, …}` | `{id}` | uiOnly |
| `vm.clone` | `{id, name}` | `{id}` | uiOnly |
| `vm.delete` | `{id}` | `{}` | uiOnly |
| `vm.import` | `{path}` | `{id}` | uiOnly |
<!-- contract:methods:end -->

`vm.settings.apply` reports each changed setting by path (`cpu.count`, `network.0.mode`, `shares`): `applied`
(in effect now: host-side settings, live changes, anything while the VM is stopped), `nextBoot` (saved, used at
the next start) or `rejected` (identity, disks, install source, unknown keys; not saved, see `reasons`). Which
settings change live is `docs/live-capabilities.md`.

`vm.settings.apply` is uiOnly when its patch touches `mcp`, `clipboard`, `shares`, `agent` or `windows`, or
contains a port rule whose host address is not loopback (`127.0.0.1`, `::1`, `localhost`): any other address
exposes the guest beyond this Mac. `library.*` and `vm.create/clone/delete/import`
run in Core directly (no helper needed) through `LibraryOps`, behind the same policy check.

## Notifications

Sent to clients subscribed (`events.subscribe`) to the topic. The `console` topic (the serial console's output, which can show what is typed
at it) needs `control` for clients other than the app and an operator.

<!-- contract:notifications:begin -->
| notification | params |
|---|---|
| `vm.stateChanged` | `{state, reason}` |
| `agent.connectionChanged` | `{connected}` |
| `agent.activity` | `vm.agent.activity`'s result (topic `vm`, the app's connections only), after every agent request, a take over, a resume, a stop and a kill switch change |
| `screen.accessibilityNeeded` | `{}` (topic `agent`: a guest refused its controls until the user allows VMPane Agent Accessibility; the VM window says so, once) |
| `exec.output` | `{execId, stream, dataB64}` |
| `exec.exited` | `{execId, code, signal}` |
| `console.output` | `{dataB64}` |
| `snapshot.progress` | `{id, percent}` |
| `install.progress` | `{phase, percent, message}`; subscribing to `install` while a Windows install runs sends the current one at once |
| `files.progress` | `{bytesDone, bytesTotal, file}` (during `vm.files.drop`) |
| `agent.toolsUpdate` | `{state, version, message}` (topic `agent`: `state` updating, updated or failed, as an older Linux or Windows agent updates itself from the helper's tools; the VM window shows `message`) |
<!-- contract:notifications:end -->

An exec's `exec.output` and `exec.exited` can arrive before the `agent.exec` answer that names its `execId` (a
quick command; callers other than the app are audited before their answer): keep notifications that come while
the call is open, and match them once the id is known.

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
| -32018 | macLocked | saved VM memory cannot be restored while this Mac is locked; the state is kept, start again after unlocking |
| -32019 | takenOver | the person at the Mac took over the VM from AI agents (`vm.agent.takeOver`); retry after they resume |
