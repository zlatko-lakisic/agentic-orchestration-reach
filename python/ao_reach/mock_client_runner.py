#!/usr/bin/env python3
"""CLI mock Reach client for edge custom-tool smoke (fictional tools per profile)."""

from __future__ import annotations

import argparse
import asyncio
import json
import logging
import sys
from pathlib import Path

from ao_reach.connection_config import ReachConnectionConfig, ensure_reach_identity
from ao_reach.hybrid_mcp_bootstrap import CustomToolDeploySpec, HybridSessionMcpBootstrap, mock_profile_tools
from ao_reach.session_bridge import SessionBridge
from ao_reach.tool_packager import package_custom_tool

_LOGGER = logging.getLogger(__name__)

REPO_ROOT = Path(__file__).resolve().parents[2]
ECHO_PROJECT = REPO_ROOT / "test" / "fixtures" / "custom_tools" / "echo_tool"


def _echo_manifest(tool_id: str) -> dict:
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


def _tools_for_profile(profile: str) -> list[CustomToolDeploySpec]:
    out: list[CustomToolDeploySpec] = []
    for spec in mock_profile_tools(profile):
        out.append(
            CustomToolDeploySpec(
                tool_id=spec.tool_id,
                description=spec.description,
                manifest=_echo_manifest(spec.tool_id),
                project_dir=ECHO_PROJECT,
                alias=spec.alias,
            )
        )
    return out


async def _run(args: argparse.Namespace) -> int:
    user, session = ensure_reach_identity(
        user_name=args.user,
        session_id=args.session,
        session_prefix=args.profile,
    )
    headers = {
        "x-agentic-user-name": user,
        "x-agentic-session-id": session,
        "Accept": "application/json",
    }
    config = ReachConnectionConfig(
        base_url=args.base_url.rstrip("/"),
        app_id=args.profile,
        headers=headers,
        deploy_to_ao_sandbox=not args.tunnel_only,
        ttl_seconds=args.ttl,
    )
    bootstrap = HybridSessionMcpBootstrap(tools=_tools_for_profile(args.profile))
    bridge = SessionBridge()
    overlay_root = args.overlay_root or str(REPO_ROOT / "test" / "fixtures")

    if args.pack_only:
        for spec in _tools_for_profile(args.profile):
            bundle = package_custom_tool(manifest=spec.manifest, project_dir=ECHO_PROJECT)
            print(json.dumps({"toolId": bundle.manifest.tool_id, "zipSha256": bundle.zip_sha256}))
        return 0

    try:
        await bridge.start(
            config=config,
            overlay_root=overlay_root,
            mcp_bootstrap=bootstrap,
        )
    except Exception as exc:  # noqa: BLE001
        _LOGGER.error("session start failed: %s", exc)
        return 1

    print(
        json.dumps(
            {
                "profile": args.profile,
                "sandbox": config.deploy_to_ao_sandbox,
                "aoCustomToolSandbox": bridge.custom_tool_sandbox,
                "registeredMcpIds": bridge.registered_mcp_ids,
                "warnings": bridge.client_mcp_warnings,
            },
            indent=2,
        )
    )
    await bridge.stop()
    return 0


def main() -> None:
    parser = argparse.ArgumentParser(description="Mock Reach client (custom-tool smoke)")
    parser.add_argument(
        "--profile",
        required=True,
        choices=["mock-comstar", "mock-continue", "mock-ha"],
    )
    parser.add_argument("--base-url", default="http://127.0.0.1:8765")
    parser.add_argument("--overlay-root", default="")
    parser.add_argument("--user", default="")
    parser.add_argument("--session", default="")
    parser.add_argument("--ttl", type=int, default=3600)
    parser.add_argument("--tunnel-only", action="store_true")
    parser.add_argument("--pack-only", action="store_true")
    parser.add_argument("-v", "--verbose", action="store_true")
    args = parser.parse_args()
    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.INFO)
    raise SystemExit(asyncio.run(_run(args)))


if __name__ == "__main__":
    main()
