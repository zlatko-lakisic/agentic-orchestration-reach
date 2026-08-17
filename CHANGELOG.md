# Changelog

All notable changes to **agentic-orchestration-reach** (AO Reach) are documented here.

## [Unreleased]

### Added

- **`images` on `chat` / `directAgent` / `runDynamic`** — send ordered stills as `[{mimeType, dataBase64, name?}]` (`image/jpeg|png|webp|gif`) and AO answers with a vision model instead of the planner. Optional and omitted from the payload when empty, so existing calls are unchanged; engines older than the multimodal protocol ignore the field. AO enforces 16 images / 4 MiB each / 20 MiB total and fails with `invalid_images`, `payload_too_large`, or `vision_unavailable` rather than answering without seeing them.

## [0.9.0] - 2026-08-13

### Added

- **`ReachRunStatus` / `onStatus`** — stream AO background progress during `chat` / `directAgent` (`processing`, `phase`, user-friendly `message`). Failures throw `ReachRunException` / `ReachRunError` with `code` so the app can handle them. Also: `runStatusUpdates` (Dart) and `on_run_status` (Python).

## [0.8.0] - 2026-08-13

### Added

- **`ReachCatalogClient` / `GET /api/v1/catalog`** — fetch stock agents, MCPs, skills, harnesses and per-entry `requiredSecrets` for enablement UIs (Dart + Python).
- **`allowedMcpProviderIds` / `allowedSkillIds`** on `ReachConnectionConfig` — sent on `session_overlay_register` with `sessionEnv` secrets for enabled catalog entries.

## [0.7.1] - 2026-08-13

### Fixed

- **mTLS enroller** — `await` `persistReachMtlsMaterial` inside try/finally so `dart analyze` passes (`unawaited_return_in_try_block`).

## [0.7.0] - 2026-08-13

### Added

- **`ReachConnectionConfig.sessionEnv` / `allowedAgentProviderIds`** — pass provider API keys and stock agent allowlists on `session_overlay_register` (AO applies session-scoped env + planner allowlist).

## [0.6.0] - 2026-08-12

### Added

- **`SessionBridge.chat` / `runDynamic`** — AO engine dynamic planning (`type: chat`) with per-call `runMode`, `selectedAgentProviderIds`, and `appId`.
- **`ReachConnectionConfig.dynamicPlanning` / `defaultRunMode`** — sticky defaults for dynamic chat (AO Admin can also set per-`appId` prefs on matching AO builds).

## [0.5.2] - 2026-08-08

### Fixed

- **LocalMcpHost / mcp-proxy spawn** — bind `--host 127.0.0.1`, enable `--stateless`,
  and pass the stdio server via `--shell` as one command string. Nested
  `npx -y <package>` as positionals was failing health/initialize with
  `sh: method:initialize: command not found` (Gmail/Calendar and other npx MCPs).

## [0.5.1] - 2026-08-08

### Fixed

- Restore `SessionBridge.refreshOverlay` + TTL auto-refresh (regressed in 0.5.0).
  Refresh includes required `appId`.

## [0.5.0] - 2026-08-08

### Breaking

- **`ReachConnectionConfig.appId` is required** — product apps must advertise a
  stable client id (e.g. `myapp`, `field-client`) on every `session_overlay_register`.
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
