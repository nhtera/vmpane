# Release checklist (manual)

What the integration tests do not cover, checked on the notarized candidate before `publish`. Note who checked,
on which Mac and macOS build.

- [ ] Fresh install from the DMG on a Mac account that never ran VMPane: Gatekeeper opens it without warnings;
      the welcome screens show; `vmpane install-cli` works.
- [ ] Wizard, each guest OS: macOS (IPSW), Ubuntu (ISO), Windows 11 (ISO, unattended): installs to a desktop;
      the guest tools install; the VM restarts cleanly.
- [ ] Dock: each running VM has its own Dock tile with its icon; the Dock menu acts on it.
- [ ] VoiceOver: the library, the wizard, a VM window's toolbar and Settings can be used without a mouse.
- [ ] Update with running VMs (once Sparkle's feed is live): from the previous version, with a Linux and a
      Windows VM running, Check for Updates → Suspend All and Update → after the relaunch both resume where they
      were; Update Now leaves them running on the old helper until restarted.
- [ ] AI agents with the real clients: Claude Code, Codex CLI and Gemini CLI each, after `vmpane mcp config
      <client> --apply` on a clean account: list → screenshot → click → type → exec (the confirmation shows) →
      undo the session. Stop All AI Agents ends a running command.
- [ ] `vmpane doctor --diagnostics ~/Desktop/d.zip`: the zip has no passwords, keys, disks, ISOs or memory.
- [ ] The website's download link and the Homebrew cask point at this release's DMG; `SHA256SUMS` matches.
