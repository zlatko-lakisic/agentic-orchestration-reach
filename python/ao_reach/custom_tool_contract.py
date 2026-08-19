"""Shared wheel+manifest contract for AO custom-tool sandbox deployment (v1)."""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from typing import Any

CONTRACT_VERSION = "1"
SUPPORTED_RUNTIMES = frozenset({"python"})
FALLBACK_POLICIES = frozenset({"tunnel", "fail"})
TOOL_ID_PATTERN = re.compile(r"^client\.[a-z][a-z0-9_]*\.[a-z][a-z0-9_]+$")
SEMVER_PATTERN = re.compile(r"^\d+\.\d+\.\d+(-[a-zA-Z0-9.]+)?(\+[a-zA-Z0-9.]+)?$")


class CustomToolContractError(ValueError):
    """Manifest or bundle failed contract validation."""


@dataclass(frozen=True)
class CustomToolPermissions:
    filesystem: tuple[str, ...] = ()
    network: bool = False
    env: tuple[str, ...] = ()

    @classmethod
    def from_json(cls, raw: Any) -> CustomToolPermissions:
        if not isinstance(raw, dict):
            raise CustomToolContractError("permissions must be an object")
        fs_raw = raw.get("filesystem") or []
        env_raw = raw.get("env") or []
        fs = tuple(str(x).strip() for x in fs_raw if str(x).strip()) if isinstance(fs_raw, list) else ()
        env = tuple(str(x).strip() for x in env_raw if str(x).strip()) if isinstance(env_raw, list) else ()
        return cls(
            filesystem=fs,
            network=bool(raw.get("network")),
            env=env,
        )


@dataclass(frozen=True)
class CustomToolHealthcheck:
    path: str = "/health"
    timeout_seconds: int = 5

    @classmethod
    def from_json(cls, raw: Any) -> CustomToolHealthcheck:
        if not isinstance(raw, dict):
            raise CustomToolContractError("healthcheck must be an object")
        path = str(raw.get("path") or "/health").strip() or "/health"
        timeout = raw.get("timeoutSeconds", 5)
        if not isinstance(timeout, (int, float)) or timeout <= 0:
            raise CustomToolContractError("healthcheck.timeoutSeconds must be a positive number")
        return cls(path=path, timeout_seconds=int(timeout))


@dataclass(frozen=True)
class CustomToolManifest:
    contract_version: str
    tool_id: str
    tool_version: str
    runtime: str
    wheel: str
    entrypoints: dict[str, str]
    required_env: tuple[str, ...] = ()
    permissions: CustomToolPermissions = field(default_factory=CustomToolPermissions)
    healthcheck: CustomToolHealthcheck = field(default_factory=CustomToolHealthcheck)
    fallback_policy: str = "tunnel"
    raw: dict[str, Any] = field(default_factory=dict, compare=False)

    @classmethod
    def from_json(cls, data: dict[str, Any]) -> CustomToolManifest:
        validate_manifest_dict(data)
        entry_raw = data.get("entrypoints") or {}
        entrypoints = {str(k): str(v) for k, v in entry_raw.items()} if isinstance(entry_raw, dict) else {}
        req_raw = data.get("requiredEnv") or []
        required_env = (
            tuple(str(x).strip() for x in req_raw if str(x).strip()) if isinstance(req_raw, list) else ()
        )
        return cls(
            contract_version=str(data["contractVersion"]),
            tool_id=str(data["toolId"]),
            tool_version=str(data["toolVersion"]),
            runtime=str(data["runtime"]),
            wheel=str(data["wheel"]),
            entrypoints=entrypoints,
            required_env=required_env,
            permissions=CustomToolPermissions.from_json(data.get("permissions") or {}),
            healthcheck=CustomToolHealthcheck.from_json(data.get("healthcheck") or {}),
            fallback_policy=str(data.get("fallbackPolicy") or "tunnel"),
            raw=dict(data),
        )

    def to_json(self) -> dict[str, Any]:
        return {
            "contractVersion": self.contract_version,
            "toolId": self.tool_id,
            "toolVersion": self.tool_version,
            "runtime": self.runtime,
            "wheel": self.wheel,
            "entrypoints": dict(self.entrypoints),
            "requiredEnv": list(self.required_env),
            "permissions": {
                "filesystem": list(self.permissions.filesystem),
                "network": self.permissions.network,
                "env": list(self.permissions.env),
            },
            "healthcheck": {
                "path": self.healthcheck.path,
                "timeoutSeconds": self.healthcheck.timeout_seconds,
            },
            "fallbackPolicy": self.fallback_policy,
        }


def validate_manifest_dict(data: Any) -> None:
    """Raise [CustomToolContractError] when *data* is not a valid v1 manifest."""
    if not isinstance(data, dict):
        raise CustomToolContractError("manifest must be a JSON object")

    required = ("contractVersion", "toolId", "toolVersion", "runtime", "wheel", "entrypoints")
    for key in required:
        if key not in data or data[key] in (None, ""):
            raise CustomToolContractError(f"manifest missing required field: {key}")

    version = str(data["contractVersion"]).strip()
    if version != CONTRACT_VERSION:
        raise CustomToolContractError(
            f"unsupported contractVersion {version!r} (expected {CONTRACT_VERSION!r})"
        )

    tool_id = str(data["toolId"]).strip()
    if not TOOL_ID_PATTERN.match(tool_id):
        raise CustomToolContractError(
            f"toolId must match client.<app>.<name> (e.g. client.mock_comstar.echo_tool): {tool_id!r}"
        )

    tool_version = str(data["toolVersion"]).strip()
    if not SEMVER_PATTERN.match(tool_version):
        raise CustomToolContractError(f"toolVersion must be semver: {tool_version!r}")

    runtime = str(data["runtime"]).strip().lower()
    if runtime not in SUPPORTED_RUNTIMES:
        raise CustomToolContractError(f"unsupported runtime {runtime!r}")

    wheel = str(data["wheel"]).strip()
    if not wheel.endswith(".whl"):
        raise CustomToolContractError("wheel must be a .whl filename")

    entry_raw = data.get("entrypoints")
    if not isinstance(entry_raw, dict) or not entry_raw:
        raise CustomToolContractError("entrypoints must be a non-empty object")
    if "mcp" not in entry_raw or not str(entry_raw["mcp"]).strip():
        raise CustomToolContractError("entrypoints.mcp is required")

    fallback = str(data.get("fallbackPolicy") or "tunnel").strip().lower()
    if fallback not in FALLBACK_POLICIES:
        raise CustomToolContractError(f"fallbackPolicy must be one of {sorted(FALLBACK_POLICIES)}")

    CustomToolPermissions.from_json(data.get("permissions") or {})
    CustomToolHealthcheck.from_json(data.get("healthcheck") or {})


def app_id_from_tool_id(tool_id: str) -> str:
    """Map ``client.mock_comstar.echo`` → ``mock-comstar`` (hyphenated app id)."""
    parts = tool_id.split(".")
    if len(parts) < 3 or parts[0] != "client":
        raise CustomToolContractError(f"invalid toolId: {tool_id!r}")
    segment = parts[1]
    return segment.replace("_", "-")
