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
qemu/scripts/build-deps.sh            # incremental; --clean starts over (downloads are kept)
qemu/scripts/build-deps.sh --fetch-only   # download and verify every tarball
```

A clean build takes about 6 minutes on an M4 Pro.

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

## Components

Each entry in `deps.lock` has its version, URL, SHA-256, licence and patches. `role: tool` entries are
build-only; `role: runtime` entries are shipped. Patches are in `patches/<component>/`, each starting with
a header giving its origin and the reason for it.

Choices that are not obvious from the recipes (`scripts/lib/recipes.sh`):

- **QEMU** is built for HVF only (`--disable-tcg`) with the device allowlist in
  [`configs/devices-vmpane.mak`](configs/devices-vmpane.mak) (see [SECURITY-DEVICES.md](SECURITY-DEVICES.md)).
  `qemu-system-aarch64 -accel help` lists only `hvf`.
- **swtpm:** only `swtpm` and `swtpm_setup` are built; the certificate tools need GnuTLS and GMP.
- **GStreamer:** core and base libraries only, no plugins and no pipeline-string parser. spice-gtk cannot
  link without them; VMPane plays guest audio through QEMU's CoreAudio backend, not SPICE.
- **spice-gtk** carries UTM's patch set (Apache-2.0, see `LICENSES/UTM`), which CocoaSpice needs.
- **pcre2** has no JIT: QEMU's hardened runtime has no `allow-jit` entitlement.
- **dtc** (libfdt) is built separately because QEMU's copy is a download-only subproject.

## Updating a component

1. Change its `version`, `url` and `sha256` in `deps.lock` (take the hash from the project's published
   checksums when it has them).
2. Rebase its patches, if any.
3. Rebuild, then run the QEMU itests. A QEMU or EDK2 update also needs the Windows boot itests.

## Replacing a library (LGPL)

The LGPL libraries (glib, GStreamer, spice-gtk, libusb, usbredir and others in `deps.lock`) are shipped as
separate dynamic libraries and can be replaced:

- **QEMU side:** build your own QEMU (or this one with your changed library), sign it ad hoc with
  `Config/Entitlements/qemu.entitlements`, and select its directory under Advanced settings → QEMU.
- **App side** (libraries loaded by VMPane itself): replace the `.dylib` in the app bundle and re-sign the
  whole app ad hoc with `VMPANE_SIGN_IDENTITY=- scripts/sign.sh <VMPane.app>`. macOS only loads libraries
  signed by the same team as the app, so the whole app has to be re-signed; an app signed this way no
  longer receives updates.
