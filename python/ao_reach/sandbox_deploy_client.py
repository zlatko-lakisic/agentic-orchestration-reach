"""HTTP client for AO custom-tool sandbox upload + activate."""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

from .connection_config import ReachConnectionConfig
from .tool_packager import CustomToolBundle


@dataclass
class SandboxDeployResult:
    ok: bool
    mcp: dict[str, Any] | None = None
    mcp_entry: dict[str, Any] | None = None
    runtime: dict[str, Any] | None = None
    reused: bool = False
    error: str | None = None
    fallback_reason: str | None = None
    tool_id: str = ""
    tool_version: str = ""
    status: str = ""
    artifact_id: str | None = None
    sandbox_url: str | None = None
    raw: dict[str, Any] = field(default_factory=dict)

    def __post_init__(self) -> None:
        if self.mcp_entry is None and self.mcp is not None:
            self.mcp_entry = self.mcp


class ReachSandboxDeployClient:
    """Upload and activate wheel+manifest bundles against AO REST APIs.

    Assumed AO REST contract (feature-flagged on engine):

    - ``POST /api/v1/custom-tools/upload?appId={appId}``
      — raw zip body, ``Content-Type: application/zip``.
      Returns ``{artifactId?, toolId, toolVersion, status}``.
    - ``POST /api/v1/custom-tools/activate``
      — JSON ``{appId, toolId, toolVersion, env?}``.
      Returns ``{ok, mcp, runtime?, reused?}`` where ``mcp`` is the overlay entry.
    """

    def __init__(
        self,
        *,
        base_url: str = "",
        headers: dict[str, str] | None = None,
        timeout_s: float = 60.0,
    ) -> None:
        self.base_url = base_url.rstrip("/")
        self.headers = dict(headers or {})
        self.timeout_s = timeout_s

    def _request(
        self,
        method: str,
        path: str,
        *,
        body: bytes | None = None,
        json_body: dict[str, Any] | None = None,
        content_type: str | None = None,
        headers: dict[str, str] | None = None,
    ) -> dict[str, Any]:
        url = f"{self.base_url.rstrip('/')}{path}"
        hdrs = dict(self.headers)
        if headers:
            hdrs.update(headers)
        data = body
        if json_body is not None:
            data = json.dumps(json_body).encode("utf-8")
            hdrs.setdefault("Content-Type", "application/json")
        if content_type:
            hdrs["Content-Type"] = content_type
        req = Request(url, data=data, headers=hdrs, method=method)
        try:
            with urlopen(req, timeout=self.timeout_s) as resp:
                raw = resp.read().decode("utf-8")
                return json.loads(raw) if raw else {}
        except HTTPError as exc:
            detail = exc.read().decode("utf-8", errors="replace")
            raise RuntimeError(f"{method} {path} failed ({exc.code}): {detail}") from exc
        except URLError as exc:
            raise RuntimeError(f"{method} {path} failed: {exc}") from exc

    def upload(self, config: ReachConnectionConfig, bundle: CustomToolBundle) -> dict[str, Any]:
        base = config.base_url.rstrip("/")
        prev_base, prev_headers = self.base_url, self.headers
        self.base_url = base
        self.headers = dict(config.headers)
        try:
            return self._request(
                "POST",
                f"/api/v1/custom-tools/upload?appId={config.app_id}",
                body=bundle.zip_bytes,
                content_type="application/zip",
            )
        finally:
            self.base_url, self.headers = prev_base, prev_headers

    def activate(
        self,
        config: ReachConnectionConfig,
        *,
        tool_id: str,
        tool_version: str,
        env: dict[str, str] | None = None,
    ) -> SandboxDeployResult:
        base = config.base_url.rstrip("/")
        prev_base, prev_headers = self.base_url, self.headers
        self.base_url = base
        self.headers = dict(config.headers)
        try:
            payload = self._request(
                "POST",
                "/api/v1/custom-tools/activate",
                json_body={
                    "appId": config.app_id,
                    "toolId": tool_id,
                    "toolVersion": tool_version,
                    "env": env or {},
                },
            )
        except RuntimeError as exc:
            return SandboxDeployResult(
                ok=False,
                error=str(exc),
                fallback_reason="ao_activate_failed",
                tool_id=tool_id,
                tool_version=tool_version,
            )
        finally:
            self.base_url, self.headers = prev_base, prev_headers

        mcp = payload.get("mcp") if isinstance(payload.get("mcp"), dict) else None
        if mcp is None and isinstance(payload.get("mcpEntry"), dict):
            mcp = payload["mcpEntry"]
        runtime = payload.get("runtime") if isinstance(payload.get("runtime"), dict) else None
        return SandboxDeployResult(
            ok=bool(payload.get("ok", mcp is not None)),
            mcp=mcp,
            mcp_entry=mcp,
            runtime=runtime,
            reused=bool(payload.get("reused")),
            tool_id=tool_id,
            tool_version=tool_version,
            status="active" if mcp else "failed",
            sandbox_url=payload.get("sandboxUrl"),
            raw=payload,
        )

    def deploy_bundle(
        self,
        config: ReachConnectionConfig,
        bundle: CustomToolBundle,
        *,
        env: dict[str, str] | None = None,
    ) -> SandboxDeployResult:
        try:
            self.upload(config, bundle)
        except RuntimeError as exc:
            return SandboxDeployResult(
                ok=False,
                error=str(exc),
                fallback_reason="ao_upload_failed",
                tool_id=bundle.manifest.tool_id,
                tool_version=bundle.manifest.tool_version,
            )
        return self.activate(
            config,
            tool_id=bundle.manifest.tool_id,
            tool_version=bundle.manifest.tool_version,
            env=env,
        )

    async def upload_and_activate(
        self,
        config: ReachConnectionConfig,
        bundle: CustomToolBundle,
        *,
        env: dict[str, str] | None = None,
    ) -> SandboxDeployResult:
        return self.deploy_bundle(config, bundle, env=env)


SandboxDeployClient = ReachSandboxDeployClient
