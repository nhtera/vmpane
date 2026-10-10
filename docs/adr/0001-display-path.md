# ADR 0001: Display path for Windows guests

- Status: accepted
- Date: 2026-10-10

## Context

Windows guests run in QEMU, so the host needs its own display client with dynamic resolution and
clipboard sharing. Options:

- **A**: reuse UTM's dependency build and its CocoaSpice client.
- **B**: write our own Swift SPICE client on top of spice-glib (about two extra weeks).
- **C**: QEMU's VNC server and our own RFB client (about two extra weeks, and no USB redirection).

UTM builds QEMU as a shared library loaded by its own launcher and always builds GStreamer and a full GPU
stack. That does not fit our design, where QEMU is a sandboxed child process. CocoaSpice (Apache-2.0) is
a standalone Swift package that only needs glib, spice-client-glib and GStreamer's core libraries.

## Decision

**A, modified**: our own minimal dependency build, upstream QEMU built as an executable with SPICE, and
CocoaSpice (the no-USB variant first) with a small patch set.

A prototype built this stack (spice-protocol 0.14.5, spice-server 0.16.0, QEMU 11.1.2 with
`--enable-spice --enable-hvf`, spice-gtk 0.42) and rendered a Windows 11 guest's desktop over
`-spice unix` through CocoaSpice's Metal renderer, checked by reading back the rendered drawable.

## What the build needs

- spice-gtk 0.42 with UTM's five patches: CocoaSpice runs SPICE on its own GLib main context
  (`spice_util_set_main_context`), and one patch fixes the macOS link.
- spice-server: one line, `librt` does not exist on macOS.
- CocoaSpice:
  - no static GStreamer plugin registration on macOS;
  - no process-wide `HOME`/`TMPDIR`/`XDG_*` overrides from its iOS start-up code;
  - build vertices before the canvas texture when a renderer is attached. Without this the first frame
    is dropped and a static guest screen stays black until the guest redraws (reproduced and fixed;
    worth sending upstream);
  - compile against our build's headers instead of its bundled ones (spice-gtk 0.40, GStreamer 1.19).
- GStreamer: spice-gtk requires its core libraries (about 3.6 MB, LGPL, linked dynamically). We ship no
  plugins and never use SPICE audio or video streaming: audio goes through QEMU's CoreAudio backend, and
  QEMU's SPICE video streaming stays off. Plugin scanning is disabled at start-up; with it on, the first
  connection stalled for over a minute.

## Consequences

- The QEMU and SPICE build script and the patch set are ours to maintain (Phase 04).
- As built (Phase 05): CocoaSpice is vendored (`Packages/VMPaneSpice`, `scripts/vendor-cocoaspice.sh`)
  with three patches: vertices first, no GStreamer initialisation at all, and shaders compiled from
  embedded source (no Xcode-only metallib). It builds against generated headers and link stubs of our
  libraries (`SpiceSDK/`); the helper weak-links them and embeds them from the QEMU bundle, so it still
  builds and runs VZ VMs without them. VNC is not built, so there is no fallback display path.
- QEMU's spice-server can hang in its cleanup when QEMU exits with a client connected: the helper
  disconnects before every quit, and QEMU runs with `-no-shutdown` so a guest power-off waits for that.
- Dynamic resolution and clipboard need an ARM64 build of spice-vdagent in the Windows guest (upstream
  ships x86 and x64 only). If none is usable, our own guest agent handles resize and clipboard.
- Windows blanks its display when idle, which shows as a black SPICE canvas; the helper should keep the
  guest display awake while its window is visible, or show that the display is asleep.
