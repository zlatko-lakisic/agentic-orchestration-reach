"""Deterministic stdio MCP stub (echo) for Reach e2e fixtures."""

from __future__ import annotations

import json
import sys


def main() -> None:
    """Minimal MCP initialize/tools/list loop for health checks."""
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except json.JSONDecodeError:
            continue
        method = req.get("method")
        req_id = req.get("id")
        if method == "initialize":
            _reply(
                req_id,
                {
                    "protocolVersion": "2024-11-05",
                    "capabilities": {"tools": {}},
                    "serverInfo": {"name": "echo-tool", "version": "0.1.0"},
                },
            )
        elif method == "tools/list":
            _reply(
                req_id,
                {
                    "tools": [
                        {
                            "name": "echo",
                            "description": "Echo input text",
                            "inputSchema": {
                                "type": "object",
                                "properties": {"text": {"type": "string"}},
                            },
                        }
                    ]
                },
            )
        elif method == "tools/call":
            params = req.get("params") or {}
            text = ""
            if isinstance(params.get("arguments"), dict):
                text = str(params["arguments"].get("text") or "")
            _reply(req_id, {"content": [{"type": "text", "text": text}]})


def _reply(req_id: object, result: dict) -> None:
    sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": req_id, "result": result}) + "\n")
    sys.stdout.flush()


if __name__ == "__main__":
    main()
