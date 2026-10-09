#!/usr/bin/env bash
# Register this Mac as the project's self-hosted GitHub Actions runner (labels: self-hosted, macOS, ARM64,
# vmpane). Run as an admin user with `gh` logged in as a repository admin; it uses sudo.
#   - creates the standard (non-admin) user `vmpane-ci` if missing (prompts for a password for it);
#   - installs the pinned runner release (sha256-verified) in that user's home;
#   - registers it with a short-lived registration token that is never printed;
#   - runs it as a LaunchDaemon under `vmpane-ci`, so it works without anyone logged in.
# The runner user has no access to your keychain, signing identities or files.
# Usage: scripts/setup-runner.sh [--uninstall]
set -euo pipefail

repo=nhtera/vmpane
user=vmpane-ci
version=2.338.0
sha256=df4cebda25c86a886ed204e49fee63f5c2e7cec5f447b5c98440a826bbdf9df2
label=app.vmpane.ci-runner
plist=/Library/LaunchDaemons/$label.plist
home=/Users/$user
dir=$home/actions-runner

if [[ "${1:-}" == --uninstall ]]; then
    sudo launchctl bootout "system/$label" 2>/dev/null || true
    sudo rm -f "$plist"
    if [[ -x "$dir/config.sh" ]]; then
        token=$(gh api -X POST "repos/$repo/actions/runners/remove-token" -q .token)
        sudo -u "$user" -H bash -c 'cd "$1" && ./config.sh remove --token "$2"' _ "$dir" "$token" >/dev/null
    fi
    echo "runner removed (user $user kept; delete it in System Settings > Users & Groups if wanted)"
    exit 0
fi

[[ "$(uname -m)" == arm64 ]] || { echo "error: Apple-silicon Mac required" >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "error: run 'gh auth login' first" >&2; exit 1; }

if ! id "$user" >/dev/null 2>&1; then
    echo "Creating standard user $user. Choose a password for it (you will not need it day to day):"
    sudo sysadminctl -addUser "$user" -fullName "VMPane CI" -password - -home "$home"
    sudo createhomedir -c -u "$user" >/dev/null
    # Keep it off the login window.
    sudo dscl . create "/Users/$user" IsHidden 1
fi

if [[ ! -x "$dir/run.sh" ]]; then
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    curl -fsSL -o "$tmp/runner.tar.gz" \
        "https://github.com/actions/runner/releases/download/v$version/actions-runner-osx-arm64-$version.tar.gz"
    if [[ "$(shasum -a 256 "$tmp/runner.tar.gz" | awk '{print $1}')" != "$sha256" ]]; then
        echo "error: runner archive sha256 mismatch" >&2
        exit 1
    fi
    sudo -u "$user" -H mkdir -p "$dir"
    # Fed on stdin: the runner user cannot read this user's private temp folder.
    sudo -u "$user" -H tar -xzf - -C "$dir" <"$tmp/runner.tar.gz"
fi

if [[ ! -f "$dir/.runner" ]]; then
    # Registration tokens expire after an hour; it goes straight to config.sh and is never echoed.
    token=$(gh api -X POST "repos/$repo/actions/runners/registration-token" -q .token)
    sudo -u "$user" -H bash -c 'cd "$1" && ./config.sh --unattended --replace --url "$2" --token "$3" \
        --name "$4" --labels vmpane --work _work' \
        _ "$dir" "https://github.com/$repo" "$token" "vmpane-$(scutil --get LocalHostName)" >/dev/null
    echo "runner registered"
fi

sudo tee "$plist" >/dev/null <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$label</string>
  <key>UserName</key><string>$user</string>
  <key>WorkingDirectory</key><string>$dir</string>
  <key>ProgramArguments</key><array><string>$dir/run.sh</string></array>
  <key>EnvironmentVariables</key><dict>
    <key>HOME</key><string>$home</string>
    <key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardOutPath</key><string>$dir/_diag/launchd.log</string>
  <key>StandardErrorPath</key><string>$dir/_diag/launchd.log</string>
</dict>
</plist>
EOF
sudo chown root:wheel "$plist"
sudo chmod 644 "$plist"
sudo launchctl bootout "system/$label" 2>/dev/null || true
sudo launchctl bootstrap system "$plist"
echo "runner service started ($label); check: gh api repos/$repo/actions/runners -q '.runners[] | .name + \" \" + .status'"
