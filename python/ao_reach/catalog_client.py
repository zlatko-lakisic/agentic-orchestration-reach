"""Fetch AO stock catalog (agents / MCPs / skills / harnesses + requiredSecrets)."""

from __future__ import annotations

import json
import ssl
import tempfile
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import aiohttp

from .connection_config import ReachConnectionConfig
from .mtls import assert_reach_mtls_uses_tls, load_reach_mtls_material


def _ssl_context_for_config(config: ReachConnectionConfig) -> ssl.SSLContext | None:
    if not config.mtls or not config.mtls.is_configured:
        return None
    assert_reach_mtls_uses_tls(config.base_url)
    material = load_reach_mtls_material(config.mtls)
    if material.dir:
        material_path = Path(material.dir)
    else:
        material_path = Path(tempfile.mkdtemp(prefix="ao-reach-catalog-mtls-"))
        (material_path / "cert.pem").write_text(material.client_cert_pem, encoding="utf-8")
        (material_path / "key.pem").write_text(material.client_key_pem, encoding="utf-8")
        (material_path / "ca.pem").write_text(material.ca_pem, encoding="utf-8")
    ctx = ssl.create_default_context(cafile=str(material_path / "ca.pem"))
    ctx.load_cert_chain(
        certfile=str(material_path / "cert.pem"),
        keyfile=str(material_path / "key.pem"),
    )
    return ctx


@dataclass(frozen=True)
class ReachCatalogSecretField:
    name: str
    label: str
    secret: bool = True
    required: bool = False
    any_of_group: str | None = None
    session_env_allowed: bool = True

    @classmethod
    def from_json(cls, raw: dict[str, Any]) -> ReachCatalogSecretField:
        return cls(
            name=str(raw.get("name") or "").strip(),
            label=str(raw.get("label") or raw.get("name") or "").strip(),
            secret=raw.get("secret") is not False,
            required=bool(raw.get("required")),
            any_of_group=(str(raw["anyOfGroup"]) if raw.get("anyOfGroup") is not None else None),
            session_env_allowed=raw.get("sessionEnvAllowed") is not False,
        )


@dataclass(frozen=True)
class ReachCatalogEntry:
    id: str
    kind: str
    type: str | None = None
    role: str | None = None
    goal: str | None = None
    model: str | None = None
    description: str | None = None
    planner_hint: str | None = None
    harness_profile: str | None = None
    transport: str | None = None
    enable_field: str | None = None
    required_secrets: tuple[ReachCatalogSecretField, ...] = ()
    raw: dict[str, Any] = field(default_factory=dict)

    @classmethod
    def from_json(cls, raw: dict[str, Any], *, kind: str | None = None) -> ReachCatalogEntry:
        secrets_raw = raw.get("requiredSecrets") or []
        secrets: list[ReachCatalogSecretField] = []
        if isinstance(secrets_raw, list):
            for item in secrets_raw:
                if isinstance(item, dict):
                    secrets.append(ReachCatalogSecretField.from_json(item))
        return cls(
            id=str(raw.get("id") or "").strip(),
            kind=str(kind or raw.get("kind") or "").strip(),
            type=(str(raw["type"]) if raw.get("type") is not None else None),
            role=(str(raw["role"]) if raw.get("role") is not None else None),
            goal=(str(raw["goal"]) if raw.get("goal") is not None else None),
            model=(str(raw["model"]) if raw.get("model") is not None else None),
            description=(str(raw["description"]) if raw.get("description") is not None else None),
            planner_hint=(str(raw["plannerHint"]) if raw.get("plannerHint") is not None else None),
            harness_profile=(
                str(raw["harnessProfile"]) if raw.get("harnessProfile") is not None else None
            ),
            transport=(str(raw["transport"]) if raw.get("transport") is not None else None),
            enable_field=(str(raw["enableField"]) if raw.get("enableField") is not None else None),
            required_secrets=tuple(secrets),
            raw=dict(raw),
        )


@dataclass(frozen=True)
class ReachCatalog:
    agents: tuple[ReachCatalogEntry, ...]
    mcps: tuple[ReachCatalogEntry, ...]
    skills: tuple[ReachCatalogEntry, ...]
    harnesses: tuple[ReachCatalogEntry, ...]
    session_env_allowed_keys: tuple[str, ...]
    enable_fields: dict[str, str | None]
    generated_at: str | None = None
    raw: dict[str, Any] = field(default_factory=dict)

    @classmethod
    def from_json(cls, data: dict[str, Any]) -> ReachCatalog:
        def parse_list(key: str, kind: str) -> tuple[ReachCatalogEntry, ...]:
            raw = data.get(key) or []
            if not isinstance(raw, list):
                return ()
            out: list[ReachCatalogEntry] = []
            for item in raw:
                if isinstance(item, dict):
                    out.append(ReachCatalogEntry.from_json(item, kind=kind))
            return tuple(out)

        keys_raw = data.get("sessionEnvAllowedKeys") or []
        keys = (
            tuple(str(k).strip() for k in keys_raw if str(k).strip())
            if isinstance(keys_raw, list)
            else ()
        )
        enable_raw = data.get("enableFields") or {}
        enable: dict[str, str | None] = {}
        if isinstance(enable_raw, dict):
            for k, v in enable_raw.items():
                enable[str(k)] = None if v is None else str(v)

        return cls(
            agents=parse_list("agents", "agent"),
            mcps=parse_list("mcps", "mcp"),
            skills=parse_list("skills", "skill"),
            harnesses=parse_list("harnesses", "harness"),
            session_env_allowed_keys=keys,
            enable_fields=enable,
            generated_at=(str(data["generatedAt"]) if data.get("generatedAt") is not None else None),
            raw=dict(data),
        )

    @property
    def all(self) -> tuple[ReachCatalogEntry, ...]:
        return self.agents + self.mcps + self.skills + self.harnesses


class ReachCatalogClient:
    """HTTP client for ``GET /api/v1/catalog``."""

    def __init__(self, session: aiohttp.ClientSession | None = None) -> None:
        self._session = session

    async def fetch(
        self,
        config: ReachConnectionConfig,
        *,
        kinds: list[str] | None = None,
    ) -> ReachCatalog:
        base = config.base_url.rstrip("/")
        params: dict[str, str] = {}
        if kinds:
            params["kinds"] = ",".join(kinds)
        url = f"{base}/api/v1/catalog"

        owned = False
        session = self._session
        if session is None:
            ssl_ctx = _ssl_context_for_config(config)
            connector = aiohttp.TCPConnector(ssl=ssl_ctx) if ssl_ctx else None
            session = aiohttp.ClientSession(connector=connector)
            owned = True

        try:
            async with session.get(
                url,
                params=params or None,
                headers={**config.headers, "Accept": "application/json"},
            ) as res:
                body = await res.text()
                if res.status < 200 or res.status >= 300:
                    raise RuntimeError(f"GET /api/v1/catalog failed: HTTP {res.status} {body}")
                data = json.loads(body)
                if not isinstance(data, dict):
                    raise RuntimeError("GET /api/v1/catalog: expected JSON object")
                return ReachCatalog.from_json(data)
        finally:
            if owned and session is not None:
                await session.close()
