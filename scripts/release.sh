#!/usr/bin/env bash
# VMPane's release, in three stages run on the maintainer's Mac (keys stay in its keychain):
#   scripts/release.sh build-candidate <version> [--dry-run] [--no-notarize]
#       preflight → Release build → sign (manifest) + verify → DMG → notarize + staple → Gatekeeper; records the
#       candidate (build/release/<version>/candidate.json, with the DMG's SHA-256)
#   scripts/release.sh itest <version> --tier beta|release
#       runs the tier's scenarios (itest/tiers.json) against that exact DMG; results are keyed by its SHA-256
#   scripts/release.sh publish <version> [--dry-run]
#       gate: a passing, clean result for the candidate × every tier scenario (× hosts for the release tier);
#       then the corresponding source, SHA256SUMS, the appcast and the cask, and (not in --dry-run) the GitHub
#       Release, the appcast on the gh-pages branch (after the DMG it offers) and the tap pull request
# --dry-run: preflight problems that only a real release needs (tag, CI run, signed Windows tools) are warnings,
# and nothing is published.
set -euo pipefail
cd "$(dirname "$0")/.."

stage=${1:-}
version=${2:-}
[[ -n $stage && -n $version ]] || { sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
shift 2
dry=false notarize=true tier=
while (($#)); do
    case "$1" in
        --dry-run) dry=true ;;
        --no-notarize) notarize=false ;;
        --tier) tier=${2:?--tier beta|release}; shift ;;
        *) echo "unknown option $1" >&2; exit 2 ;;
    esac
    shift
done
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+(-(alpha|beta|rc)\.[0-9]+)?$ ]] || { echo "error: version '$version' is not x.y.z[-beta.n]" >&2; exit 2; }
out=build/release/$version
repo=nhtera/vmpane
feed=https://nhtera.github.io/vmpane/appcast.xml
sparkle=build/dd/SourcePackages/artifacts/sparkle/Sparkle/bin
candidate=$out/candidate.json
problems=0

# A problem a real release cannot have: an error, or in --dry-run a warning.
problem() {
    if $dry; then echo "warning: $*" >&2; else echo "error: $*" >&2; problems=$((problems + 1)); fi
}

preflight() {
    [[ -z $(git status --porcelain) ]] || problem "the working tree is not clean"
    [[ $(git rev-parse HEAD) == $(git rev-parse -q --verify "refs/tags/v$version^{commit}" 2>/dev/null || echo none) ]] \
        || problem "HEAD is not tagged v$version"
    grep -q "^## \[$version\]" CHANGELOG.md || problem "CHANGELOG.md has no '## [$version]' entry"
    local marketing core agent
    marketing=$(sed -n 's/^MARKETING_VERSION = //p' Config/Base.xcconfig)
    core=$(sed -n 's/.*public static let version = "\(.*\)"/\1/p' Packages/VMPaneKit/Sources/VMPaneCore/VMPaneCore.swift)
    agent=$(sed -n 's/^version = "\(.*\)"/\1/p' agent/Cargo.toml | head -1)
    [[ $marketing == "$version" ]] || problem "Config/Base.xcconfig MARKETING_VERSION is $marketing"
    [[ $core == "$version" ]] || problem "VMPane.version (VMPaneCore.swift) is $core"
    [[ $agent == "$version" ]] || problem "the agent's version (agent/Cargo.toml) is $agent"
    # Sparkle orders updates by CFBundleVersion: every release needs a higher one than the last.
    local build previous_tag previous
    build=$(sed -n 's/^CURRENT_PROJECT_VERSION = //p' Config/Base.xcconfig)
    previous_tag=$(git describe --tags --abbrev=0 --match 'v*' "HEAD^" 2>/dev/null || true)
    if [[ -n $previous_tag ]]; then
        previous=$(git show "$previous_tag:Config/Base.xcconfig" | sed -n 's/^CURRENT_PROJECT_VERSION = //p')
        ((build > previous)) || problem "CURRENT_PROJECT_VERSION ($build) is not above $previous_tag's ($previous)"
    fi
    # The agent installers come from CI (agent-release.yml) for this tag, with attestations.
    local run
    run=$(gh run list --workflow agent-release.yml --branch "v$version" --json conclusion --jq '.[0].conclusion' 2>/dev/null || true)
    [[ $run == success ]] || problem "agent-release.yml has no successful run for v$version (${run:-none})"
    local msi
    msi=$(compgen -G "build/guest-tools/windows-extra/*.msi" | head -1 || true)
    if [[ -z $msi ]]; then
        problem "no Windows agent MSI in build/guest-tools/windows-extra (guest-tools/fetch-agent-msi.sh)"
    elif ! command -v osslsigncode >/dev/null || ! osslsigncode verify -in "$msi" >/dev/null 2>&1; then
        problem "$msi is not Authenticode-signed (or osslsigncode is missing)"
    fi
    # The app embeds the macOS agent package as built: a guest opening an unsigned one gets a Gatekeeper refusal.
    local pkg="build/guest-tools/macos/VMPane Agent.pkg" assessment
    assessment=$(spctl -a -t install -vv "$pkg" 2>&1 || true)
    [[ $assessment == *"source=Notarized Developer ID"* ]] \
        || problem "$pkg is not signed and notarized (VMPANE_INSTALLER_IDENTITY=… VMPANE_NOTARIZE=1 guest-tools/build-macos.sh)"
    [[ -n ${VMPANE_SIGN_IDENTITY:-} && $VMPANE_SIGN_IDENTITY != - ]] || problem "VMPANE_SIGN_IDENTITY is not a Developer ID identity"
    ((problems == 0)) || { echo "preflight: $problems problem(s)" >&2; exit 1; }
    echo "preflight: ok"
}

build_candidate() {
    preflight
    mkdir -p "$out"
    compgen -G "build/guest-tools/vmpane-guest-tools-windows-*.iso" >/dev/null || guest-tools/build-iso.sh
    scripts/build.sh Release
    local app=build/Release/VMPane.app dmg=$out/VMPane-$version.dmg
    scripts/sign.sh --verify "$app"
    scripts/make-dmg.sh "$app" "$dmg"
    if $notarize; then
        scripts/notarize.sh "$dmg"
        xcrun stapler validate "$dmg"
    else
        echo "warning: not notarized (--no-notarize): this DMG is not a release candidate" >&2
    fi
    jq -n --arg v "$version" --arg dmg "$dmg" --arg sha "$(shasum -a 256 "$dmg" | cut -d' ' -f1)" \
        --arg git "$(git rev-parse HEAD)" --argjson notarized "$notarize" --argjson dry "$dry" \
        '{version: $v, dmg: $dmg, sha256: $sha, gitSha: $git, notarized: $notarized, dryRun: $dry}' >"$candidate"
    echo "candidate: $(jq -c . "$candidate")"
}

tier_scenarios() {
    jq -r --arg t "$1" '. as $all | $all.tiers[$t].scenarios[] | $all[.][]' itest/tiers.json
}

run_itests() {
    [[ $tier == beta || $tier == release ]] || { echo "error: --tier beta|release" >&2; exit 2; }
    [[ -f $candidate ]] || { echo "error: no candidate for $version (build-candidate first)" >&2; exit 1; }
    local dmg scenario failed=0
    dmg=$(jq -r .dmg "$candidate")
    # Each scenario once: a rerun would hide a flaky one (quarantine it with an issue instead).
    for scenario in $(tier_scenarios "$tier"); do
        scripts/itest.sh "$scenario" --app "$dmg" || failed=$((failed + 1))
    done
    ((failed == 0)) || { echo "itest: $failed scenario(s) of the $tier tier did not pass" >&2; exit 1; }
}

publish() {
    [[ -n $tier ]] || tier=$([[ $version == *-* ]] && echo beta || echo release)
    [[ -f $candidate ]] || { echo "error: no candidate for $version" >&2; exit 1; }
    local sha dmg missing=0 scenario hosts needed
    sha=$(jq -r .sha256 "$candidate")
    dmg=$(jq -r .dmg "$candidate")
    [[ $(shasum -a 256 "$dmg" | cut -d' ' -f1) == "$sha" ]] || { echo "error: $dmg changed since it was built" >&2; exit 1; }
    [[ $(jq -r .notarized "$candidate") == true ]] || problem "the candidate is not notarized"
    needed=$(jq -r --arg t "$tier" '.tiers[$t].hosts' itest/tiers.json)
    # A result counts only for this DMG, when it passed, was not skipped and came from a clean tree.
    while read -r scenario; do
        hosts=$({ cat itest/results/"$sha-$scenario"-*.json 2>/dev/null || true; } \
            | jq -s '[.[] | select(.result == "pass" and .dirty == false) | "\(.chip) \(.macOSBuild)"] | unique | length')
        if ((hosts < needed)); then
            echo "missing: $scenario passed on $hosts of $needed host(s)" >&2
            missing=$((missing + 1))
        fi
    done < <(tier_scenarios "$tier")
    ((missing == 0)) || problem "$missing scenario(s) of the $tier tier have no passing result for $sha"
    ((problems == 0)) || exit 1

    qemu/scripts/source-bundle.sh --out "$out/vmpane-$version-corresponding-source.tar.zst"
    qemu/scripts/source-bundle.sh --verify "$out/vmpane-$version-corresponding-source.tar.zst"
    # The ISO the candidate carries (the app's copy), published as is.
    local mount
    mount=$(mktemp -d)
    hdiutil attach -quiet -nobrowse -readonly -mountpoint "$mount" "$dmg"
    cp "$mount/VMPane.app/Contents/Resources/GuestTools/vmpane-guest-tools-windows.iso" "$out/vmpane-guest-tools-$version-windows.iso"
    hdiutil detach -quiet "$mount"
    (cd "$out" && shasum -a 256 VMPane-*.dmg vmpane-* >SHA256SUMS)
    local notes=$out/notes.md
    awk -v v="$version" '$0 ~ "^## \\[" v "\\]" {on = 1; next} on && /^## \[/ {exit} on' CHANGELOG.md >"$notes"
    local assets=("$dmg" "$out/vmpane-$version-corresponding-source.tar.zst" "$out/vmpane-guest-tools-$version-windows.iso" "$out/SHA256SUMS")
    local prerelease=--latest
    [[ $version == *-* ]] && prerelease=--prerelease
    make_appcast "$dmg" "$notes"
    cask "$sha" >"$out/vmpane.rb"
    if $dry; then
        echo "publish (dry run): would run"
        echo "  gh release create v$version $prerelease --title 'VMPane $version' --notes-file $notes ${assets[*]}"
        echo "  $out/appcast/appcast.xml to the gh-pages branch ($feed)"
        echo "  a pull request to nhtera/homebrew-tap with $out/vmpane.rb"
        return 0
    fi
    gh release create "v$version" "$prerelease" --repo "$repo" --title "VMPane $version" --notes-file "$notes" "${assets[@]}"
    # The DMG is public before the appcast offers it.
    publish_appcast
    tap_pr
    echo "published v$version"
}

# The published appcast plus an item for this DMG, EdDSA-signed with the key in this Mac's keychain (account
# vmpane): $out/appcast/appcast.xml. A beta goes on Sparkle's beta channel.
make_appcast() {
    local dmg=$1 notes=$2 dir=$out/appcast channel=() public
    public=$(sed -n 's/^VMPANE_SPARKLE_PUBLIC_KEY = //p' Config/Release.xcconfig)
    [[ $("$sparkle/generate_keys" --account vmpane -p 2>/dev/null) == "$public" ]] \
        || { echo "error: the keychain's Sparkle key (account vmpane) is not the app's (Release.xcconfig)" >&2; exit 1; }
    rm -rf "$dir"
    mkdir -p "$dir"
    git fetch -q origin gh-pages
    git show origin/gh-pages:appcast.xml >"$dir/appcast.xml"
    cp -c "$dmg" "$dir/"
    cp "$notes" "$dir/VMPane-$version.md"
    [[ $version == *-* ]] && channel=(--channel beta)
    # Every earlier item stays (--maximum-versions 0): the feed is the whole history.
    "$sparkle/generate_appcast" --account vmpane --maximum-versions 0 --embed-release-notes \
        --download-url-prefix "https://github.com/$repo/releases/download/v$version/" \
        --full-release-notes-url "https://github.com/$repo/releases/tag/v$version" \
        --link "https://github.com/$repo" ${channel[@]+"${channel[@]}"} "$dir" >/dev/null
    rm -rf "$dir/VMPane-$version.dmg" "$dir/VMPane-$version.md" "$dir/old_updates"
    # The new item: this version, this DMG's length, and a signature that verifies.
    local enclosure signature
    enclosure=$(xmllint --xpath "//item[*[local-name()='shortVersionString']='$version']/enclosure" "$dir/appcast.xml" 2>/dev/null) \
        || { echo "error: the appcast has no item for $version" >&2; exit 1; }
    [[ $enclosure == *" length=\"$(stat -f %z "$dmg")\""* ]] \
        || { echo "error: the appcast item's length is not the DMG's" >&2; exit 1; }
    signature=$(sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p' <<<"$enclosure")
    "$sparkle/sign_update" --account vmpane --verify "$dmg" "$signature" >/dev/null 2>&1 \
        || { echo "error: the appcast item's signature does not verify" >&2; exit 1; }
    echo "appcast: $dir/appcast.xml"
}

publish_appcast() {
    local site tries=0
    site=$(mktemp -d)
    git worktree add -q --detach "$site" origin/gh-pages
    cp "$out/appcast/appcast.xml" "$site/appcast.xml"
    git -C "$site" add appcast.xml
    git -C "$site" commit -q -m "appcast: VMPane $version"
    git -C "$site" push -q origin HEAD:gh-pages
    git worktree remove --force "$site"
    # GitHub Pages serves the new commit within minutes.
    until [[ $(curl -fsS "$feed" 2>/dev/null) == *"<sparkle:shortVersionString>$version<"* ]]; do
        ((++tries < 60)) || { echo "error: $feed does not offer $version after 10 minutes" >&2; exit 1; }
        sleep 10
    done
    echo "appcast: $feed offers $version"
}

# The Homebrew cask for this release (nhtera/homebrew-tap, Casks/vmpane.rb).
cask() {
    cat <<CASK
cask "vmpane" do
  version "$version"
  sha256 "$1"

  url "https://github.com/$repo/releases/download/v#{version}/VMPane-#{version}.dmg"
  name "VMPane"
  desc "Virtual machine manager with a CLI and an MCP server for AI agents"
  homepage "https://github.com/$repo"

  livecheck do
    url "$feed"
    strategy :sparkle
  end

  auto_updates true
  depends_on arch: :arm64
  depends_on macos: :sequoia

  app "VMPane.app"
  binary "#{appdir}/VMPane.app/Contents/Helpers/vmpane"

  # Never ~/Library/Application Support/VMPane: the VMs are the person's data.
  zap trash: [
    "~/Library/Caches/app.vmpane.mac",
    "~/Library/HTTPStorages/app.vmpane.mac",
    "~/Library/Preferences/app.vmpane.mac.plist",
    "~/Library/Saved Application State/app.vmpane.mac.savedState",
  ]
end
CASK
}

# A pull request to the tap with $out/vmpane.rb.
tap_pr() {
    local tap=nhtera/homebrew-tap branch=vmpane-$version base old existing=()
    base=$(gh api "repos/$tap/git/ref/heads/main" --jq .object.sha)
    gh api -X POST "repos/$tap/git/refs" -f ref="refs/heads/$branch" -f sha="$base" >/dev/null
    old=$(gh api "repos/$tap/contents/Casks/vmpane.rb?ref=main" --jq .sha 2>/dev/null || true)
    [[ -n $old ]] && existing=(-f sha="$old")
    gh api -X PUT "repos/$tap/contents/Casks/vmpane.rb" -f message="vmpane $version" -f branch="$branch" \
        -f content="$(base64 <"$out/vmpane.rb")" ${existing[@]+"${existing[@]}"} >/dev/null
    gh pr create --repo "$tap" --base main --head "$branch" --title "vmpane $version" \
        --body "VMPane $version: https://github.com/$repo/releases/tag/v$version"
}

case "$stage" in
    build-candidate) build_candidate ;;
    itest) run_itests ;;
    publish) publish ;;
    *) echo "unknown stage $stage (build-candidate, itest, publish)" >&2; exit 2 ;;
esac
