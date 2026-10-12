# Developer tools. Run `scripts/bootstrap.sh` (it calls `brew bundle`).
# xcodegen and swiftlint are pinned in scripts/tools.lock (installed by scripts/install-tools.sh).
brew "rustup" unless system("command -v rustup >/dev/null 2>&1")  # skip when installed from rustup.rs
brew "jsign"          # Authenticode verification of Windows guest tools
brew "osslsigncode"   # Authenticode verification
brew "xorriso"        # reproducible guest-tools ISO (guest-tools/build-iso.sh)
brew "create-dmg"     # optional: release DMG layout
brew "librsvg"        # rsvg-convert: the app icon set (scripts/gen-app-icon.sh)
