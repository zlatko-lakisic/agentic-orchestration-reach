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
- Optional speech (AO ≥ **v1.28.0**): `AGENTIC_SPEECH_ENABLED=1` + sidecars — see AO `speech/README.md`
- Optional mTLS (AO ≥ **v1.29.0**): engine TLS + client certs — see **mTLS** below
- Dart SDK ^3.5
- Node.js `npx` when spawning stdio MCPs via `LocalMcpHost`
- `openssl` on PATH when using `ReachMtlsEnroller`

## Install

```yaml
dependencies:
  ao_reach:
    git:
      url: https://github.com/zlatko-lakisic/agentic-orchestration-reach.git
      ref: v0.7.0
```

## Quick start

```dart
import 'package:ao_reach/ao_reach.dart';

final bridge = SessionBridge();

await bridge.start(
  config: ReachConnectionConfig(
    baseUrl: 'https://ao-host:8765',
    appId: 'myapp', // required stable client appId
    headers: {
      'x-agentic-session-id': 'sess-1',
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

// Dynamic planning (AO engine `type: chat`) — per-call runMode
final planned = await bridge.chat(
  text: 'Plan irrigation for zone A',
  runMode: 'dynamic', // or omit to use ReachConnectionConfig.defaultRunMode
  selectedAgentProviderIds: ['client.my_agent'],
);

await bridge.stop();
```

Set `dynamicPlanning: true` / `defaultRunMode` on `ReachConnectionConfig` for sticky app defaults (AO Admin **Access → Dynamic planning by app** can also set sticky prefs for the same `appId`).

Pass per-client keys and stock agent allowlists on the same config:

```dart
ReachConnectionConfig(
  baseUrl: 'https://ao-host:8765',
  appId: 'comstar-ha',
  headers: const {},
  sessionEnv: {
    'OPENAI_API_KEY': Platform.environment['OPENAI_API_KEY']!,
  },
  allowedAgentProviderIds: const ['gpt_research'], // not for home-assistant
);
```

### Speech (optional, AO ≥ 1.28)

When the engine advertises `speech` on `hello`:

```dart
final speech = bridge.speechClient;
if (speech != null) {
  final text = await speech.transcribe(wavBytes);
  final detailed = await speech.transcribeDetailed(wavBytes);
  // detailed.avgLogprob / noSpeechProb when sidecar sends them
  final wav = await speech.synthesize('Hello');
}
```

Pass `speechToken` on `ReachConnectionConfig` when sidecars require `AGENTIC_SPEECH_TOKEN`.  
Optional `speechSttBaseUrlOverride` / `speechTtsBaseUrlOverride` replace advertised bases after hello (AO must still advertise speech). Audio stays on HTTP to the sidecars — not on the session WebSocket.

### mTLS (optional, AO ≥ 1.29)

Reach talks to the AO **engine** directly (`https://host:8765` / `wss://…/ws`). On the AO host:

```bash
python -m orchestration.serve.mtls init-ca
python -m orchestration.serve.mtls issue-server --cn ao-engine
python -m orchestration.serve.mtls mint-token --client-name alice
# export AGENTIC_SERVE_TLS_CERTFILE/KEYFILE/CA_FILE to the printed paths
```

In the app:

```dart
final material = await ReachMtlsEnroller().enroll(
  baseUrl: 'https://ao-host:8765',
  enrollToken: tokenFromAdmin,
  materialDir: '${Platform.environment['HOME']}/.myapp/ao-mtls',
  trustEnrollmentCa: true, // or pass caPem from GET /api/v1/mtls/ca
);
await bridge.start(
  config: ReachConnectionConfig(
    baseUrl: 'https://ao-host:8765',
    appId: 'myapp',
    headers: const {},
    mtls: ReachMtlsConfig(materialDir: material.dir),
  ),
  overlayRoot: overlayRoot,
  mcpBootstrap: bootstrap,
);
```

Implement `SessionMcpBootstrap` in the product app to decide which local MCPs to start and which overlay MCP entries to register. Reach stays product-agnostic.

## Layout

| Module | Role |
|--------|------|
| `SessionBridge` | WS lifecycle, overlay register/clear, tunnel responder, `direct_agent`, `chat` / `runDynamic`, speech discovery |
| `SpeechClient` | OpenAI-compatible STT/TTS HTTP; `transcribe` / `transcribeDetailed` / `synthesize` |
| `LocalMcpHost` | Loopback `mcp-proxy` for stdio MCPs |
| `OverlayPacker` | YAML → `client.*` agents + MCP entries |
| `McpSessionSpec` | Declares stdio-tunnel vs hosted HTTP MCPs |
| `ReachConnectionConfig` | Base URL, required `appId`, headers, TTL, `dynamicPlanning` / `defaultRunMode`, speech, optional `mtls` |
| `ReachMtlsEnroller` | Token enroll → persist `cert.pem` / `key.pem` / `ca.pem` |

## Tests

```bash
dart test
```

## Python client

See [`python/`](python/) for the protocol-compatible Python `ao_reach` package (used by [HACS Comstar](https://github.com/zlatko-lakisic/hacs-comstar)).

```bash
cd python && pip install -e ".[dev]" && pytest
```

## Versioning

Semantic versioning. See `VERSION` + `CHANGELOG.md`. Git tags `vX.Y.Z` are the published artifacts apps should pin.

## Python client

See [python/](python/) for the protocol-compatible Python o_reach package (used by HACS Comstar).

