# Development

## Requirements

- An Apple-silicon Mac on macOS 15 or later.
- Xcode at the version in `.xcode-version`.
- Homebrew. `scripts/bootstrap.sh` installs the rest and generates `VMPane.xcodeproj` from `project.yml`
  (the Xcode project is generated, never committed):
  - `Brewfile`: rustup, Authenticode tools, create-dmg;
  - `scripts/tools.lock`: xcodegen and swiftlint at pinned versions, sha256-verified, into `build/tools`
    (`scripts/install-tools.sh`; every script re-runs it, so deleting `build/` is safe);
  - `agent/rust-toolchain.toml`: the Rust toolchain and targets;
  - `scripts/cargo-tools.txt`: cargo-deny, cargo-audit, cargo-about, cargo-xwin, cargo-fuzz.
- Scripts put `build/tools/bin`, `~/.cargo/bin` and Homebrew's keg-only rustup on `PATH` themselves
  (`scripts/lib/env.sh`). For an interactive shell, add `~/.cargo/bin` (rustup.rs) or
  `$(brew --prefix rustup)/bin` (Homebrew) to your `PATH`.

## Repository layout

Folder names follow the convention of the toolchain that owns them:

- **PascalCase**: Swift code and Xcode inputs, named after their target or module: `App/`, `VMHelper/`,
  `CLI/`, `UITests/`, `Packages/` (SwiftPM's `Sources/` and `Tests/`), `Config/` (xcconfigs, Info.plists,
  entitlements, signing manifest).
- **lowercase**: everything else: `agent/` (Rust workspace, kebab-case crates), `scripts/`, `docs/`,
  `itest/`, `.github/`, and generated output (`build/`, the gitignored `VMPane.xcodeproj`).

## Scripts

| script | does |
|---|---|
| `scripts/bootstrap.sh` | tools, toolchains, `xcodegen generate` |
| `scripts/lint.sh` | swiftlint, swift-format, rustfmt, clippy, workflow policy; fails on any finding |
| `scripts/test.sh [--filter <regex>] [--swift-only] [--release] [--asan]` | Swift package tests (fails if zero tests ran), then Rust tests, `cargo deny`, agent builds for macOS and Linux. `VMPANE_XWIN=1` also cross-builds the Windows agent (cargo-xwin downloads the MSVC CRT and Windows SDK, accepting Microsoft's licence) |
| `scripts/build.sh [Debug\|Release]` | builds `build/<Configuration>/VMPane.app` and signs it from the manifest (ad hoc unless `$VMPANE_SIGN_IDENTITY` is set) |
| `scripts/sign.sh [--dry-run\|--verify] <app>` | signs inside-out from `Config/signing-manifest.json` with `$VMPANE_SIGN_IDENTITY`; `--verify` also checks runtime, timestamp and team ID for real identities |
| `scripts/make-dmg.sh <app>` | release DMG |
| `scripts/notarize.sh <dmg>` | notarytool (keychain profile `vmpane-notary` or `$VMPANE_NOTARY_PROFILE`), staple, Gatekeeper check |
| `scripts/check-dylibs.sh <app>` | no Mach-O links a library or carries a run path outside the system or the bundle (Release builds; Debug has DerivedData run paths) |
| `scripts/gen-notices.sh [--check]` | regenerates `THIRD_PARTY_NOTICES.md` |
| `scripts/itest.sh <scenario\|all> [--app <app\|dmg\|zip>] [--allow-skip]` | integration scenarios on this Mac |

Xcode signs ad hoc; that signature is for development only (Xcode adds entitlements such as
`application-identifier` to the CLI). `scripts/build.sh` re-signs every Mach-O from the manifest. To sign
with a Developer ID, set `VMPANE_SIGN_IDENTITY="Developer ID Application: …"`. Ad hoc signatures skip the
hardened runtime: without a team ID, library validation would refuse the app's own libraries.

## Tests

- Unit tests use Swift Testing in `Packages/VMPaneKit/Tests` and `cargo test` in `agent/`.
- Integration tests need real VMs, so they run locally, not on hosted CI. Each scenario in
  `itest/scenarios/` defines `scenario_run` (return 0 pass, 77 skipped, anything else fail). Results are
  written to `itest/results/` keyed by the artifact's SHA-256, scenario, chip and macOS build;
  a skipped scenario never counts as a pass.
- CI also builds and tests the Release configuration, and runs the unit tests nightly with the address
  sanitizer: some concurrency bugs only show up in optimized builds.

## CI

- Hosted runners do lint, Rust, supply-chain and notices checks, and the Swift tests and build for pull
  requests (`swift-pr`).
- `swift-release` (pushes to `main`, tags, manual runs: unit tests in debug and release, Release build,
  signing and linkage checks) and the nightly `swift-asan` run use the project's self-hosted Mac
  (`scripts/setup-runner.sh`). They never run for pull requests: `scripts/check-workflows.rb` (part of `scripts/lint.sh`) rejects
  any job not on a GitHub-hosted label unless its `if:` allowlists `push`, `workflow_dispatch` or
  `schedule`, and bans `pull_request_target`, `issue_comment` and `workflow_run`.
- Every third-party Action is pinned by commit SHA; Dependabot proposes updates for Actions and crates.
  swift-argument-parser is pinned with `exactVersion` in `project.yml`, which Dependabot cannot read:
  bump it by hand (check its releases when touching the CLI).

## Conventions

- [Conventional Commits](https://www.conventionalcommits.org/), signed off (`git commit -s`).
- Swift 6 language mode with complete concurrency checking; no warnings.
- Comments explain *why*. They do not reference plan, ticket or review identifiers.
- Decisions with lasting impact get an ADR in `docs/adr/`.
