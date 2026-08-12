"""Load AO-layout overlay catalogs into session_overlay_register payload."""

from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import yaml

from .ids import bare_agent_id, to_client_agent_id
from .mcp_session_spec import (
    McpSessionSpec,
    McpSessionTransport,
    session_tunnel_mcp_entry,
)


@dataclass
class SessionOverlayPack:
    agents: list[dict[str, Any]] = field(default_factory=list)
    mcps: list[dict[str, Any]] = field(default_factory=list)
    skills: list[dict[str, Any]] = field(default_factory=list)

    @property
    def agent_ids(self) -> list[str]:
        return [str(a.get("id") or "") for a in self.agents if a.get("id")]

    @property
    def mcp_ids(self) -> list[str]:
        return [str(m.get("id") or "") for m in self.mcps if m.get("id")]

    @property
    def skill_ids(self) -> list[str]:
        return [str(s.get("id") or "") for s in self.skills if s.get("id")]


def _strip_yaml_frontmatter(raw: str) -> str:
    t = raw.lstrip()
    if not t.startswith("---"):
        return raw
    end = t.find("\n---", 3)
    if end < 0:
        return raw
    after = t[end + 4 :]
    return after[1:] if after.startswith("\n") else after


class OverlayPacker:
    def pack(
        self,
        overlay_root: str | Path,
        *,
        include_filesystem_mcp: bool = False,
        include_email_gmail_mcp: bool = False,
        include_calendar_google_mcp: bool = False,
        tunnel_specs: list[McpSessionSpec] | None = None,
        http_mcps: list[dict] | None = None,
        extra_mcps: list[dict] | None = None,
    ) -> SessionOverlayPack:
        root = Path(overlay_root)
        agents_dir = root / "agent_providers"
        if not agents_dir.is_dir():
            raise RuntimeError(f"Overlay agent_providers missing: {agents_dir}")

        skill_by_bare = self._load_skills(root)
        skills = sorted(skill_by_bare.values(), key=lambda s: str(s.get("id") or ""))

        agents: list[dict[str, Any]] = []
        files = sorted(agents_dir.glob("*.yaml")) + sorted(agents_dir.glob("*.yml"))
        for file in files:
            raw = yaml.safe_load(file.read_text(encoding="utf-8"))
            if not isinstance(raw, dict):
                continue
            bare_id = str(raw.get("id") or "").strip()
            if not bare_id:
                continue
            out = dict(raw)
            out["id"] = to_client_agent_id(bare_id)
            if str(out.get("type") or "").lower() == "ollama":
                out.pop("ollama_host", None)
                out["selfcontained"] = False
            self._attach_skills_to_agent(out, skill_by_bare)
            agents.append(out)

        if not agents:
            raise RuntimeError(f"No agent YAML found under {agents_dir}")

        mcps: list[dict[str, Any]] = []
        seen: set[str] = set()

        def add_mcp(entry: dict[str, Any]) -> None:
            mid = str(entry.get("id") or "")
            if not mid or mid in seen:
                return
            seen.add(mid)
            mcps.append(entry)

        from .ids import (
            CALENDAR_GOOGLE_TUNNEL_ALIAS,
            CLIENT_CALENDAR_GOOGLE_MCP_ID,
            CLIENT_EMAIL_GMAIL_MCP_ID,
            CLIENT_FILESYSTEM_MCP_ID,
            EMAIL_GMAIL_TUNNEL_ALIAS,
            FILESYSTEM_TUNNEL_ALIAS,
        )

        if include_filesystem_mcp:
            add_mcp(
                session_tunnel_mcp_entry(
                    client_id=CLIENT_FILESYSTEM_MCP_ID,
                    description="User documents (session tunnel)",
                    alias=FILESYSTEM_TUNNEL_ALIAS,
                )
            )
        if include_email_gmail_mcp:
            add_mcp(
                session_tunnel_mcp_entry(
                    client_id=CLIENT_EMAIL_GMAIL_MCP_ID,
                    description="Gmail (session tunnel)",
                    alias=EMAIL_GMAIL_TUNNEL_ALIAS,
                )
            )
        if include_calendar_google_mcp:
            add_mcp(
                session_tunnel_mcp_entry(
                    client_id=CLIENT_CALENDAR_GOOGLE_MCP_ID,
                    description="Google Calendar (session tunnel)",
                    alias=CALENDAR_GOOGLE_TUNNEL_ALIAS,
                )
            )

        for spec in tunnel_specs or []:
            if spec.transport != McpSessionTransport.STDIO_TUNNEL:
                continue
            add_mcp(
                session_tunnel_mcp_entry(
                    client_id=spec.client_id,
                    description=spec.description,
                    alias=spec.alias,
                )
            )

        for entry in http_mcps or []:
            add_mcp(entry)
        for entry in extra_mcps or []:
            add_mcp(entry)

        return SessionOverlayPack(agents=agents, mcps=mcps, skills=skills)

    def _load_skills(self, overlay_root: Path) -> dict[str, dict[str, Any]]:
        skills_dir = overlay_root / "agent_skills"
        if not skills_dir.is_dir():
            return {}
        out: dict[str, dict[str, Any]] = {}
        files = sorted(skills_dir.glob("*.yaml")) + sorted(skills_dir.glob("*.yml"))
        for file in files:
            raw = yaml.safe_load(file.read_text(encoding="utf-8"))
            if not isinstance(raw, dict):
                continue
            bare_id = str(raw.get("id") or "").strip()
            if not bare_id:
                continue
            content = raw.get("content")
            if isinstance(content, dict):
                file_rel = str(content.get("file") or "").strip()
                if file_rel:
                    body_path = file.parent / file_rel
                    if body_path.is_file():
                        body = body_path.read_text(encoding="utf-8")
                        content_out = dict(content)
                        content_out.pop("file", None)
                        content_out["body"] = _strip_yaml_frontmatter(body)
                        raw["content"] = content_out
            raw["id"] = to_client_agent_id(bare_id)
            out[bare_agent_id(bare_id)] = raw
        return out

    def _attach_skills_to_agent(
        self, agent: dict[str, Any], skill_by_bare: dict[str, dict[str, Any]]
    ) -> None:
        raw = agent.get("skills")
        if not isinstance(raw, list) or not raw:
            return
        client_ids: list[str] = []
        chunks: list[str] = []
        for item in raw:
            bare = bare_agent_id(str(item))
            if not bare:
                continue
            skill = skill_by_bare.get(bare)
            if skill is None:
                continue
            client_ids.append(to_client_agent_id(bare))
            inject = skill.get("inject")
            heading = (
                inject.get("heading")
                if isinstance(inject, dict)
                else None
            ) or f"## Skill: {bare}"
            content = skill.get("content")
            body = content.get("body") if isinstance(content, dict) else ""
            body = str(body or "")
            if not body.strip():
                continue
            chunks.append(f"{heading}\n\n{body.strip()}")
        agent["skills"] = client_ids
        if not chunks:
            return
        block = "\n\n".join(chunks)
        existing = str(agent.get("backstory") or "")
        agent["backstory"] = block if not existing.strip() else f"{existing.strip()}\n\n{block}"
