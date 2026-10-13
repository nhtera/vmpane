# Release checklist (manual)

What the integration tests do not cover, checked on the notarized candidate before `publish`. Note who checked,
on which Mac and macOS build. Each item says which part the tests already check (`scripts/itest.sh <scenario>`);
only the rest is done by hand.

- [ ] Fresh install from the DMG on a Mac account that never ran VMPane: Gatekeeper opens it without warnings;
      the welcome screens show; `vmpane install-cli` works.
      *Tested:* notarization and Gatekeeper (`release.sh build-candidate`, release-verify), the welcome on a first
      launch (ui-smoke), `install-cli --user` (cli-e2e). *By hand:* the new account's first-run prompts, and
      `install-cli` with its administrator prompt.
- [ ] Wizard, each guest OS: macOS (IPSW), Ubuntu (ISO), Windows 11 (ISO, unattended): installs to a desktop;
      the guest tools install; the VM restarts cleanly.
      *Tested:* the installs themselves (macos-install, linux-iso-install, win-install). *By hand:* the wizard's
      screens up to the start of each install.
- [ ] Dock: each running VM has its own Dock tile with its icon; the Dock menu acts on it.
      *Tested:* the VM's own app has a menu bar, and its Quit asks while the VM runs (ui-smoke).
      *By hand:* the tile's icon and its menu (UITests' testDockMenuActsOnTheVM, when the Dock is not auto-hidden).
- [ ] VoiceOver: the library, the wizard, a VM window's toolbar and Settings can be used without a mouse.
      *Tested:* the accessibility audit of the welcome, the library, the wizard, Settings, a VM window and its
      settings (ui-smoke). *By hand:* VoiceOver itself.
- [ ] Update with running VMs (once Sparkle's feed is live): from the previous version, with a Linux and a
      Windows VM running, Check for Updates → Suspend All and Update → after the relaunch both resume where they
      were; Update Now leaves them running on the old helper until restarted.
      *Tested:* a VM keeps running on the old helper while the app is replaced (update-under-load); a suspended
      Windows VM resumes with its guest agent (agent-windows). *By hand:* Sparkle's own window.
- [ ] AI agents with the real clients: Claude Code, Codex CLI and Gemini CLI each, after `vmpane mcp config
      <client> --apply` on a clean account: list → screenshot → click → type → exec (the confirmation shows) →
      undo the session. Stop All AI Agents ends a running command.
      *Tested:* each installed client drives a VM through list, screenshot, click, type and exec, and `mcp config
      --apply` in a temporary home (`VMPANE_ITEST_AI_CLIENTS=1 scripts/itest.sh mcp-clients`; it uses the clients'
      model quota); the kill switch (mcp-killswitch). *By hand:* the exec confirmation and the undo, in the app.
- [ ] `vmpane doctor --diagnostics ~/Desktop/d.zip`: the zip has no passwords, keys, disks, ISOs or memory.
      *Tested:* with a running VM (cli-e2e).
- [ ] The website's download link and the Homebrew cask point at this release's DMG; `SHA256SUMS` matches.
