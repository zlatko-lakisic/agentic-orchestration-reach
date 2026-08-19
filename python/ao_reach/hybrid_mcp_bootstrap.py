"""Hybrid MCP bootstrap: AO sandbox primary, tunnel fallback."""

from __future__ import annotations

import logging
from dataclasses import dataclass
from typing import TYPE_CHECKING, Any

from .mcp_bootstrap import EmptySessionMcpBootstrap, SessionMcpBootstrapResult
from .mcp_session_spec import McpSessionSpec, McpSessionTransport, session_tunnel_mcp_entry
from .sandbox_deploy_client import ReachSandboxDeployClient
from .tool_packager import package_custom_tool

if TYPE_CHECKING:
    from .connection_config import ReachConnectionConfig
    from .local_mcp_host import LocalMcpHost
    from .mcp_bootstrap import SessionMcpBootstrap

_LOGGER = logging.getLogger(__name__)


@dataclass
class CustomToolDeploySpec:
    tool_id: str
    description: str
    manifest: dict[str, Any] | None = None
    manifest_file: Any | None = None
    wheel_file: Any | None = None
    project_dir: Any | None = None
    tunnel_spec: McpSessionSpec | None = None
    alias: str | None = None

    def resolve_bundle(self):
        from pathlib import Path

        return package_custom_tool(
            manifest=self.manifest,
            manifest_path=Path(self.manifest_file) if self.manifest_file else None,
            wheel_path=Path(self.wheel_file) if self.wheel_file else None,
            project_dir=Path(self.project_dir) if self.project_dir else None,
        )


class HybridSessionMcpBootstrap:
    """Try AO sandbox activation per tool; fall back to stdio tunnel on failure."""

    def __init__(
        self,
        *,
        tools: list[CustomToolDeploySpec],
        inner: SessionMcpBootstrap | None = None,
        deploy_client: ReachSandboxDeployClient | None = None,
        config: ReachConnectionConfig | None = None,
    ) -> None:
        self._tools = list(tools)
        self._inner = inner or EmptySessionMcpBootstrap()
        self._deploy_client = deploy_client or ReachSandboxDeployClient()
        self._config = config
        self.ao_custom_tool_sandbox = False

    async def prepare(
        self,
        host: LocalMcpHost,
        *,
        mcp_tunnel: bool,
        config: ReachConnectionConfig | None = None,
    ) -> SessionMcpBootstrapResult:
        effective = config or self._config
        inner_result = await self._inner.prepare(host, mcp_tunnel=mcp_tunnel, config=effective)

        if (
            effective is None
            or not effective.deploy_to_ao_sandbox
            or not self.ao_custom_tool_sandbox
            or not self._tools
        ):
            return inner_result

        tool_ids = {t.tool_id for t in self._tools}
        mcps = [m for m in inner_result.mcps if str(m.get("id")) not in tool_ids]
        warnings = list(inner_result.warnings)
        tunnel_ids = list(inner_result.active_tunnel_bare_ids)
        session_env = dict(effective.session_env or {})

        for spec in self._tools:
            try:
                bundle = spec.resolve_bundle()
                deployed = await self._deploy_client.upload_and_activate(
                    effective, bundle, env=session_env
                )
                if deployed.ok:
                    # AO merges activated sandbox MCPs server-side; do not
                    # register loopback sandbox URLs in session_overlay_register.
                    continue
                reason = deployed.fallback_reason or deployed.error or "sandbox_unavailable"
                raise RuntimeError(reason)
            except Exception as exc:  # noqa: BLE001
                msg = f"sandbox deploy failed for {spec.tool_id}: {exc}; using tunnel fallback"
                _LOGGER.warning(msg)
                warnings.append(msg)
                fallback = await self._tunnel_fallback(host, spec, mcp_tunnel=mcp_tunnel)
                if fallback is not None:
                    mcps.append(fallback["entry"])
                    bare = fallback.get("bare_id")
                    if bare and bare not in tunnel_ids:
                        tunnel_ids.append(str(bare))

        return SessionMcpBootstrapResult(
            mcps=mcps,
            warnings=warnings,
            filesystem_active=inner_result.filesystem_active,
            email_gmail_active=inner_result.email_gmail_active,
            calendar_google_active=inner_result.calendar_google_active,
            active_tunnel_bare_ids=tunnel_ids,
        )

    async def _tunnel_fallback(
        self,
        host: LocalMcpHost,
        spec: CustomToolDeploySpec,
        *,
        mcp_tunnel: bool,
    ) -> dict[str, Any] | None:
        if not mcp_tunnel:
            return None
        tunnel = spec.tunnel_spec
        if tunnel is None:
            bare = spec.tool_id.split(".")[-1]
            alias = spec.alias or bare
            tunnel = McpSessionSpec(
                bare_id=bare,
                alias=alias,
                transport=McpSessionTransport.STDIO_TUNNEL,
                description=spec.description,
                python_module="echo_tool.mcp",
            )
        if tunnel.transport != McpSessionTransport.STDIO_TUNNEL:
            return None
        if not host.is_alias_running(tunnel.alias):
            if tunnel.python_module:
                await host.start_python_module(alias=tunnel.alias, module=tunnel.python_module)
            elif tunnel.npx_package:
                await host.start_npx_package(alias=tunnel.alias, package=tunnel.npx_package)
            else:
                return None
        return {
            "entry": session_tunnel_mcp_entry(
                client_id=spec.tool_id,
                description=spec.description,
                alias=tunnel.alias,
            ),
            "bare_id": tunnel.bare_id,
        }


MOCK_CLIENT_PROFILES: dict[str, list[tuple[str, str]]] = {
    "mock-comstar": [
        ("client.mock_comstar.fake_lsp_bridge", "Mock LSP bridge"),
        ("client.mock_comstar.nonexistent_refactor", "Mock refactor tool"),
    ],
    "mock-continue": [
        ("client.mock_continue.fake_workspace_index", "Mock workspace index"),
        ("client.mock_continue.ghost_completion", "Mock ghost completion"),
    ],
    "mock-ha": [
        ("client.mock_ha.fake_entity_registry", "Mock HA entity registry"),
        ("client.mock_ha.synthetic_automation", "Mock HA automation"),
    ],
}


def mock_profile_tools(app_id: str) -> list[CustomToolDeploySpec]:
    tools = MOCK_CLIENT_PROFILES.get(app_id)
    if tools is None:
        raise ValueError(f"unknown mock profile: {app_id}")
    return [
        CustomToolDeploySpec(
            tool_id=tool_id,
            description=desc,
            alias=tool_id.split(".")[-1],
        )
        for tool_id, desc in tools
    ]


# Back-compat alias used by session_bridge / smoke scripts
HybridMcpBootstrap = HybridSessionMcpBootstrap
