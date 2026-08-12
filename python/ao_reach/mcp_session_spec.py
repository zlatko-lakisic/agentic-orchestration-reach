"""MCP session specs for overlay registration."""

from __future__ import annotations

from dataclasses import dataclass, field
from enum import Enum
from typing import Callable

from .ids import to_client_agent_id


class McpSessionTransport(str, Enum):
    STDIO_TUNNEL = "stdio_tunnel"
    HTTP_URL = "http_url"


@dataclass
class McpSessionSpec:
    bare_id: str
    alias: str
    transport: McpSessionTransport
    description: str
    npx_package: str | None = None
    python_module: str | None = None
    env_keys: list[str] = field(default_factory=list)
    http_url_from_env: Callable[[dict[str, str]], str | None] | None = None

    @property
    def client_id(self) -> str:
        return to_client_agent_id(self.bare_id)


def session_http_mcp_entry(*, client_id: str, description: str, url: str) -> dict:
    return {
        "id": client_id,
        "description": description,
        "streamable_http": {
            "url": url,
            "headers": {"Accept": "application/json, text/event-stream"},
        },
    }


def session_tunnel_mcp_entry(*, client_id: str, description: str, alias: str) -> dict:
    return {
        "id": client_id,
        "description": description,
        "streamable_http": {
            "url": f"tunnel://session-mcp/{alias}",
            "headers": {},
        },
    }
