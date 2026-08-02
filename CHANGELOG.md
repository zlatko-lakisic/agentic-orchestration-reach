# Changelog

All notable changes to **agentic-orchestration-reach** (AO Reach) are documented here.

## [Unreleased]

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
