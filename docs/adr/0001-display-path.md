# ADR 0001: Display path for Windows guests

- Status: proposed
- Date: 2026-10-10

## Context

Windows guests run in QEMU, so the host needs its own display client with dynamic resolution and
clipboard sharing. Options:

- **A**: reuse UTM's dependency build and its CocoaSpice client.
- **B**: write our own Swift SPICE client on top of spice-glib (about two extra weeks).
- **C**: QEMU's VNC server and our own RFB client (about two extra weeks, and no USB redirection).

What we found so far:

- UTM builds QEMU as a shared library loaded by its own launcher and always builds GStreamer and a full
  GPU stack. That does not fit our design, where QEMU is a sandboxed child process.
- CocoaSpice (Apache-2.0) is a standalone Swift package with bundled headers. It links glib and
  spice-client-glib (libusb optional) and calls `gst_init` unconditionally, so building it without
  GStreamer needs a small patch.
- Audio does not go through SPICE: QEMU's `coreaudio` backend with HDA works.
- Firmware and early boot draw to `ramfb`; the Windows desktop uses the virtio GPU driver. Resize through
  spice-vdagent is not yet tested.

## Decision (provisional)

**A, modified**: our own dependency build (recipes adapted from UTM's script: glib, pixman,
spice-protocol, spice-server, spice-glib without GStreamer, usbredir, libtpms, swtpm), upstream QEMU as an
executable, and CocoaSpice (the no-USB variant first) with a small patch.

This becomes final when a CocoaSpice sample renders a Windows guest over QEMU's `-spice unix` socket
within a fixed time box. If it does not, we switch to **B** without further discussion.

## Consequences

- The QEMU build script is ours to maintain.
- Clipboard and resize depend on an ARM64 build of spice-vdagent in the guest.
