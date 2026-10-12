# Releasing VMPane

A release runs on the maintainer's Mac: the Developer ID certificate, the notary profile and Sparkle's EdDSA key
stay in its keychain. CI builds and attests the guest agent installers (`agent-release.yml`); everything else
happens here.

## Tiers

| tier | when | gate |
|---|---|---|
| PR | every pull request (CI) | lint, unit tests, build |
| beta | every `x.y.z-beta.n` | the `core` scenarios of `itest/tiers.json` on the notarized candidate, one Mac |
| release | the first public beta, 1.0 and every minor | `core` + `full` on the candidate, two Macs (≥ 2 chips, one M3 or later; the latest macOS 26.x and 27) |

Results are keyed by the candidate DMG's SHA-256 (`itest/results/<sha>-<scenario>-<chip>-<macOS build>.json`).
A result from a dirty tree or a skipped scenario never counts. A scenario that only passed on a rerun is flaky:
open an issue and quarantine it; do not rerun until it passes.

## Steps

1. Bump the version everywhere: `MARKETING_VERSION` and a higher `CURRENT_PROJECT_VERSION` (Sparkle orders
   updates by it) in `Config/Base.xcconfig`, `VMPane.version` in `VMPaneCore.swift`, `version` in
   `agent/Cargo.toml`. Move `CHANGELOG.md`'s Unreleased entries under `## [x.y.z]`. Commit, tag `vx.y.z`, push the
   tag; wait for `agent-release.yml`.
2. `guest-tools/fetch-agent-msi.sh` (the signed MSI from that run); the macOS agent package, signed and
   notarized (the app embeds `build/guest-tools/macos` as it is):
   `VMPANE_SIGN_IDENTITY="Developer ID Application: …" VMPANE_INSTALLER_IDENTITY="Developer ID Installer: …"
   VMPANE_NOTARIZE=1 guest-tools/build-macos.sh`; then
   `VMPANE_SIGN_IDENTITY="Developer ID Application: …" scripts/release.sh build-candidate x.y.z`. It refuses a
   dirty tree, an untagged HEAD, mismatched versions, a missing CI run, an unsigned MSI or a macOS agent package
   that is not notarized; it builds Release, signs from `Config/signing-manifest.json`, verifies, makes the DMG,
   notarizes and staples it, and records the candidate's SHA-256 in `build/release/x.y.z/candidate.json`.
3. `scripts/release.sh itest x.y.z --tier beta|release` on each required Mac (copy the DMG and
   `candidate.json`; collect the result files back into `itest/results/`), with `VMPANE_SIGN_IDENTITY` set:
   `update-under-load` signs a second version of the app. Against a Developer ID app the scenarios act as an
   agent within a policy they set the way the app does (`itest/policy`); the app's own controls are not theirs.
4. `scripts/release.sh publish x.y.z` refuses unless every scenario of the tier passed for this DMG on enough
   Macs. It builds and verifies the corresponding source (GPL), writes `SHA256SUMS`, and creates the GitHub
   Release (pre-release for betas) with the DMG, source, Windows guest tools ISO and sums.
5. Appcast: `generate_appcast` (Sparkle, EdDSA key from the keychain) over the release DMGs, beta items with
   `<sparkle:channel>beta</sparkle:channel>`; deploy `appcast.xml` to vmpane.app with the site's own deploy token.
6. Homebrew: a pull request to `nhtera/homebrew-tap` updating `Casks/vmpane.rb` (version, sha256).
7. Manual checks: `docs/release-checklist.md`.

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

1. `generate_keys --account vmpane-2` (a new key in the keychain); export it right away (`generate_keys -x`) to
   two offline backups.
2. Put the new public key in `VMPANE_SPARKLE_PUBLIC_KEY`, bump the version, release normally, signing the appcast
   item with the **new** key. Installed copies accept it on the strength of the unchanged Developer ID signature.
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

### Site deploy token exposed

Revoke it at the host, check `appcast.xml` against the last published version (every item's EdDSA signature
must verify with `sign_update --verify`), redeploy, and create a new token. A forged appcast item cannot install
without a valid EdDSA signature and Developer ID signature.

### Homebrew tap compromised

Revert `Casks/vmpane.rb` to the last good commit (its `sha256` must match the GitHub Release's `SHA256SUMS`),
rotate the credentials that could push, and keep branch protection on: changes land by pull request only.
