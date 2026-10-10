# Building QEMU and its libraries

VMPane runs Windows guests (and Linux guests on request) with its own build of QEMU, swtpm and the SPICE
libraries. Every input is pinned in [`deps.lock`](deps.lock); this directory holds everything needed to
rebuild them from source.

## Requirements

- An Apple silicon Mac with the Xcode version in [`../.xcode-version`](../.xcode-version) selected
  (`xcode-select -p`). A different Xcode builds, but the binaries will not match the published ones (set
  `VMPANE_ALLOW_XCODE_MISMATCH=1` to allow it).
- Network access for the first build (tarballs and Python wheels), about 6 GB of disk.

Nothing from Homebrew or `/usr/local` is used: the build installs its own tools.

## Build

```sh
qemu/scripts/build-deps.sh            # libraries, QEMU, swtpm; incremental (--clean starts over, keeping downloads)
qemu/scripts/build-edk2.sh            # UEFI firmware, in an Ubuntu VM (needs build-deps first)
qemu/scripts/make-vars.sh             # Secure Boot variable template
qemu/scripts/package.sh               # build/qemu-bundle
scripts/check-dylibs.sh build/qemu-bundle
scripts/sign.sh --qemu-only build/qemu-bundle && scripts/sign.sh --verify --qemu-only build/qemu-bundle
```

Instead of building, `scripts/fetch-qemu-bundle.sh` installs the bundle CI built for the same inputs (see
[CI and provenance](#ci-and-provenance)). `build-deps.sh --fetch-only` downloads and verifies every tarball. On an M4 Pro a clean `build-deps.sh` takes
about 6 minutes and `build-edk2.sh` about 15.

Stages, all under `qemu/build/` (not committed):

| Path | Contents |
|---|---|
| `downloads/` | tarballs, checked against the SHA-256 in `deps.lock` on every use |
| `tools/` | build-only tools: Python (python-build-standalone) with a venv from [`tools-requirements.txt`](tools-requirements.txt) (hash-pinned meson, ninja, cmake, virt-firmware), and m4, autoconf, automake, GNU libtool (as `glibtool`) and pkgconf built from source |
| `src/` | unpacked, patched sources |
| `stage/vmpane/qemu/` | the sysroot: everything shipped, before packaging |
| `stamps/`, `logs/` | one per component |

A component is rebuilt when its `deps.lock` entry, its patches, its recipe or the shared helpers change,
and so is everything after it in the lock (the lock order is the build order).

## How the build stays reproducible

- **Hermetic environment** (`scripts/lib/env.sh`): `PATH` holds only the build tools and `/usr/bin`,
  `/bin`, `/usr/sbin`, `/sbin`; `pkg-config` sees only the sysroot; compiler and linker variables from the
  caller's shell are cleared. The build stops if `PATH` still reaches Homebrew, and after the build every
  Mach-O is checked to load only system libraries and sysroot libraries.
- **Fixed prefix:** every component is configured with `--prefix=/vmpane/qemu` and installed with
  `DESTDIR`, so the build directory is never recorded in a binary. `pkg-config` is a wrapper that runs
  `pkgconf --define-prefix`, which maps that prefix to where the sysroot really is.
- **Deterministic tools:** `SOURCE_DATE_EPOCH` from `deps.lock`, `ZERO_AR_DATE=1`, `-Wl,-reproducible` (ld
  otherwise mixes object timestamps into the UUID), `-ffile-prefix-map` for build paths, `-Wdate-time`,
  no debug info, `LC_ALL=C`, `TZ=UTC`.
- **No build paths in the layout:** the compiler is `scripts/lib/cc`, a wrapper that drops
  `-Wl,-rpath,<build dir>` (meson adds one per pkg-config dependency and deletes it at install, but the room
  it took stays in the Mach-O header, so the path's length would shift every binary). `GIT_CEILING_DIRECTORIES`
  stops version scripts from finding the surrounding checkout (spice-gtk would report `-dirty`).

- **No checkout paths in the output:** OpenSSL records its compiler command in libcrypto, so it is given
  Xcode's clang directly rather than the wrapper. `package.sh` fails if any bundle file contains the
  checkout or build directory.

Checked: clean builds from different checkouts and build directories give the same SHA-256 for every
file of the bundle; `package.sh` records these hashes in `MANIFEST.json`.

## Package

`package.sh` lays out `build/qemu-bundle`:

| Path | Contents | Goes to |
|---|---|---|
| `bin/` | qemu-system-aarch64, qemu-img, swtpm | `VMPane.app/Contents/Helpers/qemu/bin` |
| `lib/` | the libraries they load | `VMPane.app/Contents/Helpers/qemu/lib` |
| `share/` | `edk2-aarch64-code.fd`, `edk2-aarch64-vars-sb.fd` (unpadded), `qemu/efi-virtio.rom` | `VMPane.app/Contents/Resources/qemu/share` |
| `frameworks/` | SPICE client libraries (spice-client-glib and what it loads) | `VMPaneVM.app/Contents/Frameworks` |
| `MANIFEST.json` | component versions, `deps.lock` hash, SHA-256 of every file before signing | |

Load paths are relative: programs load `@rpath/<lib>` with the run path `@executable_path/../lib`, libraries
load each other with `@loader_path/<lib>`, and every library's id is `@rpath/<lib>`. Run paths from the build
are deleted, local symbols stripped. The bundle is then signed ad hoc so it runs as is; `scripts/sign.sh
--qemu-only` signs it for release from `Config/signing-manifest.json` (hardened runtime; library validation
passes because every library carries the same team ID).

QEMU's pflash devices are exactly 64 MiB, so whoever uses the firmware pads a copy (`truncate -s 64m`);
shipping the files unpadded keeps the app small.

## Firmware

`build-edk2.sh` builds EDK2 ArmVirtQemu for AARCH64 at the commit pinned in `deps.lock` (`firmware.edk2`),
with QEMU's own recipe (`roms/edk2-build.config`, aa64) plus `SECURE_BOOT_ENABLE` and TPM 2.0. EDK2 needs
GCC on Linux, so the script boots an Ubuntu VM with this pipeline's QEMU: the cloud image is pinned by
SHA-256, apt by a snapshot date (`firmware.aptSnapshot`), and the checkout is verified against the pinned
commit. It also writes the exact source it built (`edk2-src.tar.gz`, with submodules).

EDK2 stays at `edk2-stable202408`: newer releases lose virtual-timer interrupts under QEMU 11 with HVF
(boot hangs). Bisect that and report it upstream before moving.

`make-vars.sh` writes the variable store each new VM starts from, with `virt-fw-vars`:

- PK: VMPane's certificate [`firmware/vmpane-pk.pem`](firmware/vmpane-pk.pem). Its private key was
  deleted right after the certificate was made, so nothing can be signed with it and the store cannot be
  changed through PK-signed updates.
- KEK: Microsoft KEK CA 2011 and 2023 (and the VMPane certificate).
- db: Microsoft Windows Production PCA 2011, Windows UEFI CA 2023, UEFI CA 2011 and 2023, Option ROM UEFI CA 2023.
- dbx: Microsoft's arm64 revocation list (`firmware.dbx`).
- Secure Boot on.

## Components

Each entry in `deps.lock` has its version, URL, SHA-256, licence and patches. `role: tool` entries are
build-only; `role: runtime` entries are shipped. Patches are in `patches/<component>/`, each starting with
a header giving its origin and the reason for it.

Choices that are not obvious from the recipes (`scripts/lib/recipes.sh`):

- **QEMU** is built for HVF only (`--disable-tcg`) with the device allowlist in
  [`configs/devices-vmpane.mak`](configs/devices-vmpane.mak) (see [SECURITY-DEVICES.md](SECURITY-DEVICES.md)).
  `qemu-system-aarch64 -accel help` lists only `hvf`.
- **swtpm:** only `swtpm` is built. It creates a fresh TPM state on first start; Windows 11 needs no EK
  certificate, so `swtpm_setup` and the certificate tools (which need GnuTLS and GMP) are not shipped.
- **GStreamer:** core and base libraries only, no plugins and no pipeline-string parser. spice-gtk cannot
  link without them; VMPane plays guest audio through QEMU's CoreAudio backend, not SPICE.
- **spice-gtk** carries UTM's patch set (Apache-2.0, see `LICENSES/UTM`), which CocoaSpice needs.
- **pcre2** has no JIT: QEMU's hardened runtime has no `allow-jit` entitlement.
- **dtc** (libfdt) is built separately because QEMU's copy is a download-only subproject.

## Running the tools

- **Sandbox:** the helper runs QEMU and swtpm under the deny-by-default profiles in
  [`../Packages/VMPaneKit/Sources/VMPaneQEMU/Sandbox`](../Packages/VMPaneKit/Sources/VMPaneQEMU/Sandbox), shipped as
  resources of the helper (`sandbox-exec -D BUNDLE=… -D RUNDIR=… -D RUNTIME=…`, with
  `TMPDIR` set to the run directory). Each may read the runtime copy and system libraries, and read and write
  only its VM's bundle and run directory; QEMU may also open HVF and use slirp networking. The
  `qemu-sandbox` itest boots the firmware with both sandboxed, checks that each is denied a file outside its
  VM, and with `VMPANE_SIGN_IDENTITY` set does so with release-signed (hardened runtime) binaries.
- **Sound** is QEMU's CoreAudio backend, which only plays: guest microphone input has to come through SPICE
  in the helper. QEMU therefore has no `audio-input` entitlement.

## CI and provenance

`.github/workflows/qemu-deps.yml` runs on the project's Mac whenever an input changes (anything in `qemu/`
except docs and licence texts, `.xcode-version`, the QEMU entitlements). It builds everything from clean,
then `qemu/scripts/check-bundle.sh` requires the result to be exactly
[`bundle-manifest.json`](bundle-manifest.json): the same pre-signing hash for every file (the build is
reproducible, so a difference means the inputs changed without the manifest, or the build broke) and the
same as-shipped hash. The bundle is published as the artifact `qemu-bundle-<inputs hash>` (90 days) and, once
the repository is public, with a build-provenance attestation.

`scripts/fetch-qemu-bundle.sh` takes that artifact only if it comes from this workflow on `main`, its
attestation verifies (public repository), and `check-bundle.sh` passes. A release is never built from a
bundle that did not pass these checks.

## Corresponding source

```sh
qemu/scripts/source-bundle.sh --out build/vmpane-<version>-corresponding-source.tar.zst
qemu/scripts/source-bundle.sh --verify build/vmpane-<version>-corresponding-source.tar.zst
```

The archive holds `qemu/` (this directory: lock, patches, scripts, licences), the scripts and settings that
sign the bundle into the app, the source tarball of every shipped component and of the tools built from
source, and the exact EDK2 source of the firmware. `--verify` checks every file against the archive's
`SHA256SUMS` and every component against its pinned SHA-256. It is published with each release; the
written offer is in `THIRD_PARTY_NOTICES.md`.

## Updating a component

1. Change its `version`, `url` and `sha256` in `deps.lock` (take the hash from the project's published
   checksums when it has them).
2. Rebase its patches, if any.
3. Rebuild, then run the QEMU itests. A QEMU or EDK2 update also needs the Windows boot itests.
4. `qemu/scripts/extract-licenses.sh` and `scripts/gen-notices.sh` (licence texts and notices).
5. Copy the new `build/qemu-bundle/MANIFEST.json` to `bundle-manifest.json`. Any change to the build
   scripts that changes the output needs this step too; CI fails until the two agree.

## Replacing a library (LGPL)

The LGPL libraries (glib, GStreamer, spice-gtk, libusb, usbredir and others in `deps.lock`) are shipped as
separate dynamic libraries and can be replaced:

- **QEMU side:** build your own QEMU (or this one with your changed library), sign it ad hoc with
  `Config/Entitlements/qemu.entitlements`, and select its directory under Advanced settings → QEMU.
- **App side** (libraries loaded by VMPane itself): replace the `.dylib` in the app bundle and re-sign the
  whole app ad hoc with `VMPANE_SIGN_IDENTITY=- scripts/sign.sh <VMPane.app>`. macOS only loads libraries
  signed by the same team as the app, so the whole app has to be re-signed; an app signed this way no
  longer receives updates.
