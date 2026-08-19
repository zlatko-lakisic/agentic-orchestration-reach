"""Tests for custom-tool packaging, contract validation, and hybrid bootstrap."""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from ao_reach.connection_config import ReachConnectionConfig
from ao_reach.custom_tool_contract import (
    CustomToolContractError,
    CustomToolManifest,
    app_id_from_tool_id,
    validate_manifest_dict,
)
from ao_reach.hybrid_mcp_bootstrap import CustomToolDeploySpec, HybridSessionMcpBootstrap
from ao_reach.local_mcp_host import LocalMcpHost
from ao_reach.sandbox_deploy_client import ReachSandboxDeployClient
from ao_reach.tool_packager import build_bundle_zip, build_wheel, package_custom_tool

REPO_ROOT = Path(__file__).resolve().parents[2]
FIXTURE_ROOT = REPO_ROOT / "test" / "fixtures" / "custom_tools"
ECHO_PROJECT = FIXTURE_ROOT / "echo_tool"


def echo_manifest(tool_id: str) -> dict:
    return {
        "contractVersion": "1",
        "toolId": tool_id,
        "toolVersion": "0.1.0",
        "runtime": "python",
        "wheel": "echo_tool-0.1.0-py3-none-any.whl",
        "entrypoints": {"mcp": "echo_tool.mcp:main"},
        "requiredEnv": [],
        "permissions": {"filesystem": [], "network": False, "env": []},
        "healthcheck": {"path": "/health", "timeoutSeconds": 5},
        "fallbackPolicy": "tunnel",
    }


def test_validate_manifest_rejects_bad_tool_id() -> None:
    data = echo_manifest("not-a-client-id")
    with pytest.raises(CustomToolContractError):
        validate_manifest_dict(data)


def test_app_id_from_tool_id() -> None:
    assert app_id_from_tool_id("client.mock_comstar.fake_lsp_bridge") == "mock-comstar"


def test_build_wheel_and_bundle() -> None:
    wheel = build_wheel(ECHO_PROJECT)
    assert wheel.name.endswith(".whl")
    manifest = echo_manifest("client.mock_comstar.fake_lsp_bridge")
    zip_bytes = build_bundle_zip(manifest=manifest, wheel_path=wheel)
    assert zip_bytes[:2] == b"PK"
    parsed = CustomToolManifest.from_json(manifest)
    assert parsed.tool_id == "client.mock_comstar.fake_lsp_bridge"


def test_package_custom_tool_from_project_dir() -> None:
    bundle = package_custom_tool(
        manifest=echo_manifest("client.mock_ha.fake_entity_registry"),
        project_dir=ECHO_PROJECT,
    )
    assert bundle.manifest.tool_id == "client.mock_ha.fake_entity_registry"
    assert len(bundle.zip_bytes) > 100
    assert len(bundle.zip_sha256) == 64


class _MockDeployClient(ReachSandboxDeployClient):
    def __init__(self, *, fail_upload: bool = False) -> None:
        super().__init__()
        self.fail_upload = fail_upload
        self.uploads: list[str] = []

    async def upload_and_activate(self, config, bundle, *, env=None):  # type: ignore[no-untyped-def]
        from ao_reach.sandbox_deploy_client import SandboxDeployResult

        if self.fail_upload:
            return SandboxDeployResult(
                ok=False,
                error="sandbox unavailable",
                fallback_reason="ao_upload_failed",
                tool_id=bundle.manifest.tool_id,
                tool_version=bundle.manifest.tool_version,
            )
        self.uploads.append(bundle.manifest.tool_id)
        tool_id = bundle.manifest.tool_id
        return SandboxDeployResult(
            ok=True,
            mcp={
                "id": tool_id,
                "description": "sandbox",
                "streamable_http": {
                    "url": f"http://127.0.0.1:9999/sandbox/{tool_id}/mcp",
                    "headers": {"Accept": "application/json, text/event-stream"},
                },
            },
            tool_id=tool_id,
            tool_version=bundle.manifest.tool_version,
            status="active",
        )


@pytest.mark.asyncio
async def test_hybrid_bootstrap_sandbox_path() -> None:
    tool_id = "client.mock_comstar.fake_lsp_bridge"
    deploy = _MockDeployClient()
    wheel = build_wheel(ECHO_PROJECT)
    bootstrap = HybridSessionMcpBootstrap(
        tools=[
            CustomToolDeploySpec(
                tool_id=tool_id,
                description="Mock LSP bridge",
                manifest=echo_manifest(tool_id),
                wheel_file=wheel,
            )
        ],
        deploy_client=deploy,
    )
    config = ReachConnectionConfig(
        base_url="http://127.0.0.1:8765",
        app_id="mock-comstar",
        deploy_to_ao_sandbox=True,
    )
    bootstrap.ao_custom_tool_sandbox = True
    result = await bootstrap.prepare(LocalMcpHost(), mcp_tunnel=True, config=config)
    assert result.mcps == []
    assert deploy.uploads == [tool_id]
    assert not result.warnings


@pytest.mark.asyncio
async def test_hybrid_bootstrap_legacy_mode_unchanged() -> None:
    tool_id = "client.mock_comstar.fake_lsp_bridge"
    deploy = _MockDeployClient()
    bootstrap = HybridSessionMcpBootstrap(
        tools=[
            CustomToolDeploySpec(
                tool_id=tool_id,
                description="Mock LSP bridge",
                manifest=echo_manifest(tool_id),
                project_dir=ECHO_PROJECT,
            )
        ],
        deploy_client=deploy,
    )
    config = ReachConnectionConfig(
        base_url="http://127.0.0.1:8765",
        app_id="mock-comstar",
        deploy_to_ao_sandbox=False,
    )
    result = await bootstrap.prepare(LocalMcpHost(), mcp_tunnel=True, config=config)
    assert result.mcps == []
    assert deploy.uploads == []


@pytest.mark.asyncio
async def test_hybrid_bootstrap_tunnel_fallback_on_sandbox_fail() -> None:
    tool_id = "client.mock_continue.fake_workspace_index"
    deploy = _MockDeployClient(fail_upload=True)
    host = LocalMcpHost()
    host.attach_loopback_alias("fake_workspace_index", 18001)
    bootstrap = HybridSessionMcpBootstrap(
        tools=[
            CustomToolDeploySpec(
                tool_id=tool_id,
                description="Mock workspace index",
                manifest=echo_manifest(tool_id),
                project_dir=ECHO_PROJECT,
                alias="fake_workspace_index",
            )
        ],
        deploy_client=deploy,
    )
    config = ReachConnectionConfig(
        base_url="http://127.0.0.1:8765",
        app_id="mock-continue",
        deploy_to_ao_sandbox=True,
    )
    bootstrap.ao_custom_tool_sandbox = True
    result = await bootstrap.prepare(host, mcp_tunnel=True, config=config)
    assert any("tunnel fallback" in w for w in result.warnings)
    assert result.mcps[0]["streamable_http"]["url"].startswith("tunnel://")
