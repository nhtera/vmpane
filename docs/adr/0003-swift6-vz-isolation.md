# ADR 0003: Swift 6 strict concurrency with Virtualization.framework

- Status: accepted
- Date: 2026-10-10

## Context

Virtualization.framework objects are not `Sendable` and must be used on the queue the VM was created
with. VMPane runs one VM per helper process, shown in a `VZVirtualMachineView`, and also needs headless
and CLI-driven paths. The project builds in Swift 6 language mode with complete concurrency checking.

## Decision

- An `actor` owns the VM. Its `unownedExecutor` is the VM's own `DispatchSerialQueue`, and the VM is
  created with `VZVirtualMachine(configuration:queue:)` inside the actor. VZ `async` APIs are called from
  actor methods, so they resume on that queue.
- The UI receives the VM through a small `@unchecked Sendable` box, used only to set
  `VZVirtualMachineView.virtualMachine` on the main actor.
- Every VZ call path asserts `dispatchPrecondition(condition: .onQueue(vmQueue))`.

Fallback: completion-handler APIs inside `queue.async`, bridged with checked continuations.

## Rules

- No unapplied references to actor-isolated async methods (`let start = owner.start`); wrap them in
  closures.
- Build and test the Release configuration too, and run the unit tests with the address sanitizer in CI.
  A prototype that ran the VM on the main queue crashed only in optimized builds.
- Start UI work from `applicationDidFinishLaunching`.

## Evidence

A prototype of this design compiled with zero warnings under Swift 6 with warnings as errors, without
`@preconcurrency` imports, and ran headless and windowed, including as a Developer ID-signed helper.
Checked with the macOS 26.2 SDK on macOS 15.7.

## Consequences

- Several VMs per process stay possible (one actor and queue each), though v1 runs one per helper.
- Re-check when moving to the macOS 27 SDK, which adds a SwiftUI adaptor for the VM view.
