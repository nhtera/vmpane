# Release checklist (manual)

What the integration tests do not cover, checked on the notarized candidate before `publish`. Note who checked,
on which Mac and macOS build. Each item says which part the tests already check (`scripts/itest.sh <scenario>`);
only the rest is done by hand.

- [ ] Fresh install from the DMG on a Mac account that never ran VMPane: Gatekeeper opens it without warnings;
      the welcome screens show; `vmpane install-cli` works.
      *Tested:* notarization and Gatekeeper (`release.sh build-candidate`, release-verify), the welcome on a first
      launch (ui-smoke), `install-cli --user` (cli-e2e). *By hand:* the new account's first-run prompts, and
      `install-cli` with its administrator prompt.
- [ ] New VM, each system in the sheet's list: macOS (IPSW), Ubuntu, Debian and Fedora (cloud images, nothing
      typed), Windows 11 (ISO, unattended, from Customize), an installer file; a dropped .iso/.ipsw opens the sheet with it. Each is made in the background
      and installs to a desktop or a login prompt with the guest tools.
      *Tested:* the list, its keys and Customize (ui-smoke's LibraryUITests), cloud images (linux-cloud), the installs
      (macos-install, linux-iso-install, win-install), dropped ISOs read in place (unit tests). *By hand:* a
      system's Create through to the running VM, and a drop on the Dock icon.
- [ ] Dock: each running VM has its own Dock tile with its icon; the Dock menu acts on it.
      *Tested:* the VM's own app has a menu bar, and its Quit asks while the VM runs (ui-smoke).
      *By hand:* the tile's icon and its menu (UITests' testDockMenuActsOnTheVM, when the Dock is not auto-hidden).
- [ ] VoiceOver: the library, the wizard, a VM window's toolbar and Settings can be used without a mouse.
      *Tested:* the accessibility audit of the welcome, the library (with a VM: library-ui), the wizard, Settings,
      a VM window and each section of its settings (ui-smoke). *By hand:* VoiceOver itself.
- [ ] Light and dark: the new-VM sheet, the library (list, grid, inspector), a VM's settings (each section) and
      the agent HUD read well in both, with Increase Contrast and Reduce Transparency too (macOS 15 here; macOS 26
      from the beta testers' screenshots).
- [ ] Update with running VMs (once Sparkle's feed is live): from the previous version, with a Linux and a
      Windows VM running, Check for Updates → Suspend All and Update → after the relaunch both resume where they
      were; Update Now leaves them running on the old helper until restarted.
      *Tested:* a VM keeps running on the old helper while the app is replaced (update-under-load); a suspended
      Windows VM resumes with its guest agent (agent-windows). *By hand:* Sparkle's own window.
- [ ] AI agents with the real clients: Claude Code, Codex CLI and Gemini CLI each, after `vmpane mcp config
      <client> --apply` on a clean account: list → screenshot → click → type → exec (the confirmation shows) →
      undo the session. Stop All AI Agents ends a running command.
      *Tested:* each installed client drives a VM through list, screenshot, click, a vm_actions batch, vm_read_screen
      and exec, and `mcp config --apply` in a temporary home (`VMPANE_ITEST_AI_CLIENTS=1 scripts/itest.sh
      mcp-clients`; it uses the clients' model quota); the kill switch (mcp-killswitch); the HUD's Take Over and
      Resume while an agent types (agent-hud). *By hand:* the exec confirmation (now a sheet in the VM's window) and
      the undo, in the app.
- [ ] Windows microphone: with Microphone on, a microphone test in the guest (e.g. a browser's) hears the Mac's
      microphone, after macOS asks once whether "VMPane VM" may use it; with it off, Windows has no microphone.
      *Tested:* Windows lists a speaker and a microphone, its sound and its recording reach the helper over SPICE
      (win-audio; the Mac's microphone is not opened there). *By hand:* the sound itself, both ways.
- [ ] Agent sign-in on the Developer ID build: turn on "Let agents sign in" for a Windows or macOS VM, keep its
      password, lock the guest, `vm_sign_in` from a client: it signs in with no Keychain question; the inspector's
      Copy Password gives the same password.
      *Tested:* unsigned builds, with the development store (desktop-sign-in); the Keychain item's access list (the
      app and its VM helper by designated requirement) and the app's read (by hand on 2026-10-22). *By hand:* the
      helper's read on the candidate.
- [ ] `vmpane doctor --diagnostics ~/Desktop/d.zip`: the zip has no passwords, keys, disks, ISOs or memory.
      *Tested:* with a running VM (cli-e2e).
- [ ] The website's download link and the Homebrew cask point at this release's DMG; `SHA256SUMS` matches.
