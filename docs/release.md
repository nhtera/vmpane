# Releasing VMPane

A release runs on the maintainer's Mac: the Developer ID certificate, the notary profile and Sparkle's EdDSA key
stay in its keychain. CI builds and attests the guest agent installers (`agent-release.yml`); everything else
happens here.

## Tiers

| tier | when | gate |
|---|---|---|
| PR | every pull request (CI) | lint, unit tests, build |
| beta | every `x.y.z-beta.n` | the `core` scenarios of `itest/tiers.json` on the notarized candidate, one Mac |
| release | the first public beta, 1.0 and every minor | `core` + `full` on the candidate, one Mac |

The project has one Mac (an M4 Pro): other chips and macOS versions are tested by the people running the betas,
not before a release. Nested virtualization (M3 and later) is covered by that Mac; M1 and M2 behaviour is not.

Results are keyed by the candidate DMG's SHA-256 (`itest/results/<sha>-<scenario>-<chip>-<macOS build>.json`).
A result from a dirty tree or a skipped scenario never counts. A scenario that only passed on a rerun is flaky:
open an issue and quarantine it; do not rerun until it passes.

## Steps

1. Bump the version everywhere: `MARKETING_VERSION` and a higher `CURRENT_PROJECT_VERSION` (Sparkle orders
   updates by it) in `Config/Base.xcconfig`, `VMPane.version` in `VMPaneCore.swift`, `version` in
   `agent/Cargo.toml`. Move `CHANGELOG.md`'s Unreleased entries under `## [x.y.z]`. Commit, tag `vx.y.z`, push the
   tag; wait for `agent-release.yml`.
2. `guest-tools/fetch-agent-msi.sh --release vx.y.z`: the Windows agent MSI from that run, checked against its
   build-provenance attestation. It is not Authenticode-signed: the project has no Windows code-signing
   certificate (Windows Setup installs it unattended in the guest; someone installing it by hand sees "Unknown
   publisher"). The macOS agent package, signed and notarized here (the app embeds `build/guest-tools/macos` as
   it is):
   `VMPANE_SIGN_IDENTITY="Developer ID Application: …" VMPANE_INSTALLER_IDENTITY="Developer ID Installer: …"
   VMPANE_NOTARIZE=1 guest-tools/build-macos.sh`; then
   `VMPANE_SIGN_IDENTITY="Developer ID Application: …" scripts/release.sh build-candidate x.y.z`. It refuses a
   dirty tree, an untagged HEAD, mismatched versions, a missing CI run, an MSI without the tag's attestation or a
   macOS agent package that is not notarized; it builds Release, signs from `Config/signing-manifest.json`, verifies, makes the DMG,
   notarizes and staples it, and records the candidate's SHA-256 in `build/release/x.y.z/candidate.json`.
3. `scripts/release.sh itest x.y.z --tier beta|release` (on another Mac too, if `itest/tiers.json` asks for more
   hosts: copy the DMG and `candidate.json`, collect the result files back into `itest/results/`), with
   `VMPANE_SIGN_IDENTITY` set:
   `update-under-load` signs a second version of the app. Against a Developer ID app the scenarios act as an
   agent within a policy they set the way the app does (`itest/policy`); what only the app may do (sharing a
   folder while the VM runs, cancelling a Windows install) they do in the app's own windows through UI tests
   (`UITests/VMWindowUITests.swift`), and every UI test drives the candidate's app. Keep the Mac unlocked, quit
   other VMs and leave it alone while the tier runs: the UI tests take the keyboard and mouse, and find a VM's
   window by its app's bundle id.
4. `scripts/release.sh publish x.y.z` refuses unless every scenario of the tier passed for this DMG on enough
   Macs. It builds and verifies the corresponding source (GPL), writes `SHA256SUMS`, adds this DMG to the
   appcast and writes the cask; then it publishes the tag's GitHub Release (agent-release.yml's draft, a
   pre-release for betas) with the DMG, source, Windows guest tools ISO and sums, and only then publishes the appcast and opens the tap pull request:
   - **Appcast:** `appcast.xml` on the `gh-pages` branch, served by GitHub Pages at
     `https://nhtera.github.io/vmpane/appcast.xml` (the app's `SUFeedURL`, `Config/Release.xcconfig`).
     `generate_appcast` adds an item for the DMG (download from the GitHub Release), signed with the EdDSA key
     in this Mac's keychain (account `vmpane`); a beta's item is on the `beta` channel, which betas and people who
     chose "Get beta versions" follow. Every earlier item stays. `publish` checks the item's length and signature,
     and waits until Pages serves it.
   - **Homebrew:** a pull request to `nhtera/homebrew-tap` with `Casks/vmpane.rb` (version, sha256); merge it.
5. Manual checks: `docs/release-checklist.md`.

The website (https://vmpane.erai.dev, `website/`) is not part of a release: `.github/workflows/site.yml` deploys it
from `main` on its own.

`--dry-run` on `build-candidate` and `publish` turns the release-only checks into warnings and publishes nothing:
use it to rehearse.

## Rolling back

- Remove the item from `appcast.xml` (clients then see the previous one) and mark the GitHub Release as a
  pre-release with a note; revert the cask.
- Ship a fixed version: Sparkle does not downgrade.
- Config migrations keep a timestamped `.bak` next to `config.json`, so a person can go back by hand.

## Runbooks

### Sparkle EdDSA key lost or exposed

Sparkle accepts an update that changes **either** the EdDSA key **or** the Developer ID certificate, not both
(the update must be a Developer ID-signed DMG). So:

1. `generate_keys --account vmpane-2` (a new key in the keychain; the tools are in
   `build/dd/SourcePackages/artifacts/sparkle/Sparkle/bin`); export it right away (`generate_keys --account
   vmpane-2 -x <file>`) to two offline backups.
2. Put the new public key in `VMPANE_SPARKLE_PUBLIC_KEY` (`Config/Release.xcconfig`) and the new account in
   `scripts/release.sh`, bump the version, release normally: the appcast item is signed with the **new** key.
   Installed copies accept it on the strength of the unchanged Developer ID signature.
3. If the old key was exposed: remove every appcast item signed with it, and publish a security advisory
   (GitHub) saying which versions to update from by hand if Sparkle refuses.

Do not change the Developer ID certificate in the same release.

### Developer ID certificate revoked or exposed

1. Revoke it in the Apple Developer account (if exposed); request a new one.
2. The next release is signed with the new certificate and keeps the EdDSA key unchanged (see above).
3. Already-notarized DMGs keep working unless Apple revokes their tickets; if a malicious build was signed,
   ask Apple to revoke its notarization and publish an advisory.

### Notary credentials exposed

Revoke the app-specific password (appleid.apple.com) or the App Store Connect API key, then
`xcrun notarytool store-credentials vmpane-notary …` with a new one. Nothing published needs to change.

### GitHub account or token exposed

Anyone who can push to `gh-pages` can change the appcast. Revoke the token (or secure the account), check
`appcast.xml` against the last published version (every item's EdDSA signature must verify with
`sign_update --account vmpane --verify <dmg> <signature>`) and restore it. A forged appcast item cannot install
without a valid EdDSA signature and Developer ID signature.

### Homebrew tap compromised

Revert `Casks/vmpane.rb` to the last good commit (its `sha256` must match the GitHub Release's `SHA256SUMS`),
rotate the credentials that could push, and keep branch protection on: changes land by pull request only.
