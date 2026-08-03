# Changelog

All notable changes to **agentic-orchestration-reach** (AO Reach) are documented here.

## [Unreleased]

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
