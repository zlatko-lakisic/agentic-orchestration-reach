# AO Reach (Python)

Python client for [agentic-orchestration](https://github.com/zlatko-lakisic/agentic-orchestration) session overlays and reverse MCP tunnels. Protocol-compatible with the Dart `ao_reach` package.

```bash
cd python
pip install -e ".[dev]"
pytest
```

Requires AO daemon with `AGENTIC_SERVE_SESSION_OVERLAY=1` (and `AGENTIC_SERVE_MCP_TUNNEL=1` for tunnels).
