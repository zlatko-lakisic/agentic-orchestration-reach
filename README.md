# agentic-orchestration-reach (AO Reach)

Client SDK for **[agentic-orchestration](https://github.com/zlatko-lakisic/agentic-orchestration)** session overlays and reverse MCP tunnels.

Use AO Reach when a desktop / workstation app talks to a **shared** AO daemon and needs:

1. **Ephemeral `client.*` agents** registered for the session (not mounted on the host)
2. **Local tools** (filesystem, OAuth MCPs, npx stdio servers) exposed to the engine over a **WebSocket reverse tunnel** — no public Mac port, no Tailscale dial-back

Package name: `ao_reach`  
Product name: **AO Reach**

## Requirements

- AO daemon ≥ **v1.27.0** with:
  - `AGENTIC_SERVE_SESSION_OVERLAY=1`
  - `AGENTIC_SERVE_MCP_TUNNEL=1` (when registering `tunnel://session-mcp/…` MCPs)
- Dart SDK ^3.5
- Node.js `npx` when spawning stdio MCPs via `LocalMcpHost`

## Install

```yaml
dependencies:
  ao_reach:
    git:
      url: https://github.com/zlatko-lakisic/agentic-orchestration-reach.git
      ref: v0.1.0
```

## Quick start

```dart
import 'package:ao_reach/ao_reach.dart';

final bridge = SessionBridge();

await bridge.start(
  config: ReachConnectionConfig(
    baseUrl: 'https://your-ao-host',
    headers: {
      'x-agentic-user-name': 'alice',
      'x-agentic-session-id': 'sess-1',
      'x-warpgate-token': token,
    },
    ttlSeconds: 3600,
  ),
  overlayRoot: '/path/to/overlays/myapp', // contains agent_providers/*.yaml
  mcpBootstrap: MyAppMcpBootstrap(),      // start LocalMcpHost aliases + return MCP dicts
);

final result = await bridge.directAgent(
  agentProviderId: 'client.my_agent',
  text: 'Summarize Q3 pipeline',
  mcpProviderIds: ['client.filesystem_local'],
);

await bridge.stop();
```

Implement `SessionMcpBootstrap` in the product app to decide which local MCPs to start and which overlay MCP entries to register. Reach stays product-agnostic.

## Layout

| Module | Role |
|--------|------|
| `SessionBridge` | WS lifecycle, overlay register/clear, tunnel responder, `direct_agent` |
| `LocalMcpHost` | Loopback `mcp-proxy` for stdio MCPs |
| `OverlayPacker` | YAML → `client.*` agents + MCP entries |
| `McpSessionSpec` | Declares stdio-tunnel vs hosted HTTP MCPs |
| `ReachConnectionConfig` | Base URL, headers, TTL |

## Tests

```bash
dart test
```

## Versioning

Semantic versioning. See `VERSION` + `CHANGELOG.md`. Git tags `vX.Y.Z` are the published artifacts apps should pin.
