## 0.5.1

- Restore `SessionBridge.refreshOverlay` + TTL auto-refresh (regressed in 0.5.0 cut from 0.4.0 without 0.4.1). Refresh re-sends required `appId`.

# Changelog

All notable changes to **agentic-orchestration-reach** (AO Reach) are documented here.

## [Unreleased]

## [0.5.0] - 2026-08-08

### Breaking

- **`ReachConnectionConfig.appId` is required** — product apps must advertise a
  stable id (e.g. `knowbuddy`, `comstar`) on every `session_overlay_register`.
  AO denies registration with `session_overlay_denied` / `app_id_required` when
  missing. Pattern: `^[a-z][a-z0-9_-]{1,63}$` (normalized to lowercase).

## [0.4.0] - 2026-08-07

### Added

- **mTLS** — `ReachMtlsConfig` on `ReachConnectionConfig` (PEMs or `materialDir` with `cert.pem` / `key.pem` / `ca.pem`). Session WebSocket uses a `SecurityContext` client cert against the AO engine (`https`/`wss` required).
- **`ReachMtlsEnroller`** — one-time enroll against `POST /api/v1/mtls/enroll` with an AO mint-token; persists material for later connects. Requires `openssl` on PATH. Bootstrap trust via `caPem` or `trustEnrollmentCa: true` (TOFU).

## [0.3.0] - 2026-08-04

### Added

- **Speech URL overrides** — `ReachConnectionConfig.speechSttBaseUrlOverride` /
  `speechTtsBaseUrlOverride` replace advertised STT/TTS bases after `hello.speech`
  parse (AO must still advertise speech).
- **`TranscriptionResult` / `transcribeDetailed`** — optional confidence fields
  (`avgLogprob`, `noSpeechProb`, …) when the sidecar JSON includes them.
  Existing `transcribe` remains a thin wrapper returning `.text`.

### Changed

- **LocalMcpHost** — require Node.js ≥20; pin `mcp-proxy@5.12.5`; health-check
  with MCP `initialize` (not bare ping) so broken stacks fail bootstrap instead
  of soft-passing then cancelling tool discovery.
- **LocalMcpHost.startNpxPackage** — prefer a locally installed package entry
  (`~/.local/node_modules` / npm roots) via `node <main>` to avoid nested `npx`
  cold starts; default ready timeout 90s. Added `startStdioCommand` and
  `resolveInstalledPackageEntry`.
- **SessionBridge MCP tunnel** — map AO tunnel `path=/` → `/mcp`; sanitize
  CrewAI-incompatible JSON Schema union types in tool descriptors.

## [0.2.1] - 2026-08-03

### Changed

- **LocalMcpHost** — pin `mcp-proxy@5.0.0` (Node 18 compatible); drop unsupported
  flags and the `npx --` separator that swallowed the stdio server command.
- **LocalMcpHost.attachManagedLoopback** / **pickFreePort** — manage a product-owned
  loopback HTTP MCP process (e.g. Python streamable HTTP) without mcp-proxy.

## [0.2.0] - 2026-08-03

### Added

- **SpeechClient** — when AO ≥ 1.28 advertises `speech` on WebSocket `hello`, `SessionBridge.speechClient` exposes OpenAI-compatible STT (`transcribe`) and TTS (`synthesize`) over HTTP to AO-packaged sidecars. Optional `ReachConnectionConfig.speechToken` for `AGENTIC_SPEECH_TOKEN`. Absent/disabled speech leaves overlay behavior unchanged (`speechClient == null`).

## [0.1.0] - 2026-08-01

### Added

- Initial AO Reach client SDK (`ao_reach`):
  - `SessionBridge` — session overlay register/clear, MCP tunnel responder, WS `direct_agent`
  - `LocalMcpHost` — loopback `mcp-proxy` for stdio MCPs + `attachLoopbackAlias` for tests
  - `OverlayPacker` — YAML agent overlays → `client.*` + tunnel/HTTP MCP entries
  - `McpSessionSpec` / session MCP entry builders
  - `ReachConnectionConfig`, identity helpers, catalog-error helper
  - `SessionMcpBootstrap` injection point for product apps
- Regression tests: ids, packer, MCP host forward, full fake-WS protocol suite
