# VMPane for AI agents (MCP)

`vmpane mcp` is VMPane's MCP server: an AI agent (Claude Code, Codex CLI, Gemini CLI, any MCP client) starts it and
talks to it over stdin/stdout. There is no network listener. One `vmpane mcp` process is one agent session.

## Set up

```
vmpane mcp config claude     # shows the change; --apply makes it (claude mcp add …)
vmpane mcp config codex      # ~/.codex/config.toml   [mcp_servers.vmpane]
vmpane mcp config gemini     # ~/.gemini/settings.json mcpServers.vmpane
```

`--apply` keeps the old file as `<name>.vmpane-backup-<time>`. Any other client: command `<path>/vmpane`,
arguments `["mcp"]`.

Then, in VMPane, open the VM's **Settings › AI agents** and choose what agents may do with it. Every VM starts at
**Off**: agents do not even see it.

| Access | Agents may |
|---|---|
| Off | nothing (the VM is hidden) |
| Look only | see its state and screenshots, list snapshots, wait |
| Use the screen and keyboard | also click, type, press keys, start, pause, resume, take and restore snapshots, use the clipboard (when allowed) |
| Run commands | also run commands as the logged-in user and copy files in and out |
| Full control | also run commands as administrator, shut it down or turn it off, delete snapshots |

The table in `ControlMethodPolicy` (`Packages/VMPaneKit/Sources/VMPaneCore/Policy/`) is the one source of these
levels; the helper checks every call against it.

Other settings there: **Ask before an agent runs a command** (on by default: a dialog shows the command and its
input, Deny is the default, no answer in a minute is a no; it also asks before an agent restores or deletes a
snapshot or shuts the VM down, and the kill switch turns an open question into a no), **Snapshot before each agent session** (on by default),
**Record typed text** (off: typed text is recorded as a hash), **Let agents read and set the clipboard** (off).
Settings that reach beyond the VM (shared folders, removable media, networking, its name, port rules that listen
beyond this Mac) can only be changed in the app.

## Tools

| Tool | What it does |
|---|---|
| `vm_list` | VMs open to agents, with their state |
| `vm_status` | a VM's state, and whether VMPane's guest tools run in it |
| `vm_power` | `start`, `stop` (the power button), `force_stop`, `pause`, `resume` |
| `vm_screenshot` | the screen as an image (`max_edge`, default 1568); input coordinates are this image's pixels |
| `vm_click`, `vm_move`, `vm_drag`, `vm_scroll` | the mouse; `settle_ms`, `screenshot_after` |
| `vm_type`, `vm_key` | text (US layout) and keys or combinations (`cmd+c`, `ctrl+alt+delete`, `enter`, `f5`) |
| `vm_wait` | milliseconds, or until the guest tools run |
| `vm_exec` | a command (`command` for a shell, or `argv`), `as` user or admin; output, exit code |
| `vm_file_push`, `vm_file_pull` | files between the VM and `~/VMPane Exchange/<vm>/` on the Mac (only there) |
| `vm_snapshot_list`, `_create`, `_restore`, `_delete` | snapshots |
| `vm_clipboard_get`, `vm_clipboard_set` | the clipboard's text (macOS and Windows guests with the guest tools) |

Commands, files and the clipboard need VMPane's guest tools in the VM. A refused call comes back as an error result
that says why and what level it needs. Screenshots, command output and clipboard text come from the VM: treat them
as untrusted input.

## Sessions and undo

Before a session's first call that changes anything, VMPane snapshots the VM (with its memory when it runs; else
its disks, frozen through the guest tools). When it cannot, the call is refused rather than run without a way
back. The VM's snapshots list shows these as **Before agent**; **Undo This Agent Session…** restores one. The last
five are kept, and a session's own is never removed while it runs.

## Stopping every agent

**Stop All AI Agents** in VMPane's menu bar, ⌃⌥⌘. while VMPane runs, or `vmpane mcp kill` in a terminal (works
without the app). Every agent call is refused from then on, their connections close, the commands they started are
killed, their file transfers stop, and port forwards they added go down. Only the app lets them act again
(**Let AI Agents Act Again**).

## Your own terminal

`vmpane` run by you at a terminal is not an agent once you allow it: `vmpane operator grant` (asks first;
`revoke` takes it back). Then your `vmpane exec`, `stop`, `snapshot` and so on work whatever the VM's agent level,
and are recorded as `operator`. Without a terminal (scripts, agents' shells) or under `vmpane mcp`, vmpane is bound
by the levels like any agent.

## The record

Every request an agent makes of a VM, and every refusal, is a line in the VM's `logs/mcp-audit.jsonl` (in the
VM's bundle), written before the answer: who (as they claim to be), the session, the method, the level, and the
result. `vm_list` reads the library and is not recorded. See
`docs/security-model.md` for what the levels protect against and what they do not.
