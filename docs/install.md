# Install VMPane

## Requirements

- A Mac with Apple silicon (VMPane is built for arm64 only).
- macOS 15 (Sequoia) or later.
- Disk space for your VMs: a macOS install needs about 25 GB free when it starts (plus about 17 GB for a
  restore image from VMPane's catalog), and a VM's disk takes only the space its system actually uses.

## Download

Public betas will be on [GitHub Releases](https://github.com/nhtera/vmpane/releases). Each release has:

- `VMPane-<version>.dmg`: the app, signed with a Developer ID and notarized by Apple. Open it and drag VMPane to
  Applications.
- `SHA256SUMS`: the SHA-256 of the DMG, the source and the guest tools ISO (the guest agent archives are in
  `SHA256SUMS-agent`). To check your download, in the folder that holds both:

  ```sh
  shasum -a 256 -c SHA256SUMS --ignore-missing
  ```

- `vmpane-<version>-corresponding-source.tar.zst`: the source of the QEMU, swtpm, libraries and EDK2 firmware that
  VMPane bundles for Windows guests (GPL and LGPL).
- `vmpane-guest-tools-<version>-windows.iso`: the Windows guest tools (the app carries them too).

Betas are marked as pre-releases.

## Homebrew

```sh
brew install --cask nhtera/tap/vmpane
```

The cask installs VMPane.app and links the `vmpane` command onto your `PATH`.

## The `vmpane` command

Homebrew links it for you. With the DMG, run the copy inside the app once:

```sh
/Applications/VMPane.app/Contents/Helpers/vmpane install-cli          # /usr/local/bin, one administrator prompt
/Applications/VMPane.app/Contents/Helpers/vmpane install-cli --user   # ~/.local/bin, no prompt
```

With `--user`, add `~/.local/bin` to your `PATH` if it is not there yet. The link points into VMPane.app, so it
keeps working after updates; `vmpane doctor` says whether `install-cli` made it. See [`vmpane` commands](cli.md).

## First launch

VMPane opens with a welcome: what it does, that it sends no telemetry and no crash reports, and that AI agents
are off until you allow them per VM. Choose **Get Started**, then a system (macOS, Ubuntu, Debian, Fedora, Windows 11) to make your first VM. To see the
welcome again: **Settings › General › Privacy › Show the Welcome Again**.

## Updates

VMPane checks GitHub for updates and asks before installing one; it never installs an update on its own. Choose
**VMPane › Check for Updates…** to look now. If VMs are running, VMPane asks whether to update now (they keep
running on the old version until you restart them), suspend them all and resume them after the update, or wait.
With Homebrew, `brew upgrade --cask vmpane` works too (VMPane updates itself, so a plain `brew upgrade` skips it
unless you add `--greedy`).

**Betas:** turn on **Settings › General › Updates › Get beta versions**. A beta build always offers the next
betas.

## Uninstall

1. Shut down your VMs and quit VMPane.
2. Delete VMPane.app, or run `brew uninstall --cask vmpane`. `brew uninstall --zap --cask vmpane` also removes
   VMPane's caches, `app.vmpane.mac.plist`, its HTTP storage and saved state; the rest of the list below stays.
3. Remove what you no longer want. Your VMs are your data, so nothing removes them for you:

| What | Where |
|---|---|
| Your VMs, snapshots and the library | `~/Library/Application Support/VMPane` (VMs you opened from elsewhere stay where they are: delete those `.vmpane` bundles too) |
| Downloaded restore images and Linux ISOs | `~/Library/Caches/app.vmpane.mac` |
| A Windows ISO downloaded in VMPane | `~/Downloads` |
| Preferences, window positions, saved state | `~/Library/Preferences/app.vmpane.mac.plist`, `~/Library/Preferences/app.vmpane.mac.vm.plist`, `~/Library/HTTPStorages/app.vmpane.mac`, `~/Library/Saved Application State/app.vmpane.mac.savedState` |
| Files AI agents copied in and out | `~/VMPane Exchange` |
| Files a VM sent to your Mac | `~/Downloads/VMPane` |
| The `vmpane` link | `/usr/local/bin/vmpane` or `~/.local/bin/vmpane` |
| VMPane in your AI clients | `claude mcp remove vmpane` (or the `vmpane` entry of a project's `.mcp.json`); the `[mcp_servers.vmpane]` table in `~/.codex/config.toml`; `mcpServers.vmpane` in `~/.gemini/settings.json` |

VMPane installs no login items, launch agents or privileged helpers on your Mac.
