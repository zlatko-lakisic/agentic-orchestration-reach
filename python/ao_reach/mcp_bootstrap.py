"""Session MCP bootstrap protocol."""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import TYPE_CHECKING, Protocol

if TYPE_CHECKING:
    from .connection_config import ReachConnectionConfig
    from .local_mcp_host import LocalMcpHost


@dataclass
class SessionMcpBootstrapResult:
    mcps: list[dict] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)
    filesystem_active: bool = False
    email_gmail_active: bool = False
    calendar_google_active: bool = False
    active_tunnel_bare_ids: list[str] = field(default_factory=list)


class SessionMcpBootstrap(Protocol):
    async def prepare(
        self,
        host: LocalMcpHost,
        *,
        mcp_tunnel: bool,
        config: ReachConnectionConfig | None = None,
    ) -> SessionMcpBootstrapResult: ...


class EmptySessionMcpBootstrap:
    async def prepare(
        self,
        host: LocalMcpHost,
        *,
        mcp_tunnel: bool,
        config: ReachConnectionConfig | None = None,
    ) -> SessionMcpBootstrapResult:
        return SessionMcpBootstrapResult()
