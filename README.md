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
      ref: v0.9.0
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
  onStatus: (s) {
    // Stream s.message to the user; s.processing / s.phase for UI state.
    setState(() => statusLine = s.message);
  },
);
// On failure: catch ReachRunException (code, message) and decide recovery.

await bridge.stop();
```

Set `dynamicPlanning: true` / `defaultRunMode` on `ReachConnectionConfig` for sticky app defaults (AO Admin **Access → Dynamic planning by app** can also set sticky prefs for the same `appId`).

Pass per-client keys and stock allowlists on the same config (fetch the full catalogue first for UI toggles + secret fields):

```dart
final catalog = await ReachCatalogClient().fetch(
  ReachConnectionConfig(
    baseUrl: 'https://ao-host:8765',
    appId: 'comstar-ha',
    headers: const {},
    mtls: myMtls, // when engine requires mTLS
  ),
);
// catalog.agents / .mcps / .skills / .harnesses each expose requiredSecrets

ReachConnectionConfig(
  baseUrl: 'https://ao-host:8765',
  appId: 'comstar-ha',
  headers: const {},
  sessionEnv: {
    'OPENAI_API_KEY': Platform.environment['OPENAI_API_KEY']!,
    'TAVILY_API_KEY': userEnteredTavilyKey,
  },
  allowedAgentProviderIds: const ['gpt_research'],
  allowedMcpProviderIds: const ['search_tavily'],
  allowedSkillIds: const ['web_research'],
);
```

Empty allowlists mean unrestricted (current global catalog). Harness profiles are listed in the catalogue but enabled via each agent's `harnessProfile`, not a session allowlist.

### Images (optional)

`directAgent`, `chat`, and `runDynamic` accept ordered stills. AO answers those turns with a vision model instead of the planner, so the reply is plain text with no tool calls:

```dart
final verdict = await bridge.directAgent(
  agentProviderId: 'client.vision_scene_analyzer',
  text: 'Who is at the gate?',
  images: [
    {'mimeType': 'image/jpeg', 'dataBase64': base64Encode(frame1), 'name': 'gate_1.jpg'},
    {'mimeType': 'image/jpeg', 'dataBase64': base64Encode(frame2), 'name': 'gate_2.jpg'},
  ],
);
```

`mimeType` must be `image/jpeg`, `image/png`, `image/webp`, or `image/gif`. AO caps a turn at 16 images, 4 MiB each, 20 MiB total and rejects anything over that with `invalid_images` or `payload_too_large` before the run starts. If the engine has no vision-capable model configured, the run fails with `vision_unavailable` — it will not fall back to a text-only model and describe images it never saw. Prefix `text` with `[model=gpt-4o-mini]` to request a specific vision model.

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

