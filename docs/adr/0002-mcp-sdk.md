# ADR 0002: MCP server, hand-rolled for both protocol eras

- Status: accepted
- Date: 2026-10-10

## Context

`vmpane mcp` exposes VMs to AI coding agents over stdio. MCP revision 2026-07-28 dropped the
`initialize` handshake: version and capabilities travel in each request's `_meta`, with
`server/discover`, `resultType`, and error `-32022` for unsupported versions. Clients in use speak
different revisions: Claude Code prefers 2026-07-28 and falls back to 2025-11-25; Codex CLI uses
2025-06-18 with `initialize`.

## Decision

Implement the MCP server ourselves in `VMPaneMCP`, without `modelcontextprotocol/swift-sdk`:

- Serve both eras, chosen by how the client opens the session:
  - modern (2026-07-28): per-request `_meta`, `server/discover`, `resultType: "complete"`, list caching
    hints, `-32022` with the supported versions, no `ping`;
  - legacy (2025-11-25 back to 2024-11-05): `initialize`, `notifications/initialized`, `ping`.
- `tools/list` in a stable order; `tools/call` returning text, images and `structuredContent`;
  `notifications/progress`; `notifications/cancelled` (no response is sent for a cancelled request).
- No roots, sampling or logging (deprecated in 2026-07-28).

## Why not swift-sdk (0.12.1)

- Its client capabilities type `experimental` as `[String: String]`, so it cannot decode Codex's
  `initialize` request and cannot serve Codex at all.
- No support for 2026-07-28.
- A transitive dependency pinned to a branch makes builds non-reproducible.

A prototype of about 200 lines passed our wire checks and real sessions with Claude Code, Codex and
Gemini CLI (tools listed and called, images shown, progress delivered).

## Consequences

- We own protocol conformance: wire checks become unit tests, recorded client sessions become fixtures,
  and we re-run them against new client releases.
- Revisit the SDK if it supports 2026-07-28 and decodes capabilities correctly.
