"""Manifest helpers for custom-tool test fixtures."""

from __future__ import annotations

from pathlib import Path

ECHO_WHEEL_NAME = "echo_tool-0.1.0-py3-none-any.whl"
ECHO_TOOL_PROJECT = Path(__file__).resolve().parent / "echo_tool"


def echo_tool_manifest(tool_id: str, *, tool_version: str = "0.1.0") -> dict:
    return {
        "contractVersion": "1",
        "toolId": tool_id,
        "toolVersion": tool_version,
        "runtime": "python",
        "wheel": ECHO_WHEEL_NAME,
        "entrypoints": {"mcp": "echo_tool.mcp:main"},
        "requiredEnv": [],
        "permissions": {"filesystem": [], "network": False, "env": []},
        "healthcheck": {"path": "/health", "timeoutSeconds": 5},
        "fallbackPolicy": "tunnel",
    }
