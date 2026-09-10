"""Per-overlay-agent lifecycle state from AO (`type: agent_state`)."""

from __future__ import annotations

from dataclasses import dataclass
from enum import Enum
from typing import Any


class AgentLifecycleState(str, Enum):
    """Sticky per-agent readiness on a Reach session.

    ``PULLING`` is first-class (not a reason under ``STARTING``) and is used only
    for local Ollama ensure/pull.
    """

    DOWN = "down"
    STARTING = "starting"
    PULLING = "pulling"
    READY = "ready"
    BUSY = "busy"
    STOPPING = "stopping"


@dataclass(frozen=True)
class AgentStateUpdate:
    """One ``agent_state`` frame from the engine."""

    agent_provider_id: str
    state: AgentLifecycleState
    reason: str | None = None
    detail: str | None = None
    model: str | None = None
    progress: float | None = None
    question_id: str | None = None
    raw: dict[str, Any] | None = None

    @classmethod
    def from_json(cls, data: dict[str, Any]) -> AgentStateUpdate:
        pid = str(
            data.get("agentProviderId")
            or data.get("agent_provider_id")
            or ""
        ).strip()
        raw_state = str(data.get("state") or "").strip().lower()
        try:
            state = AgentLifecycleState(raw_state)
        except ValueError as exc:
            raise ValueError(f"unknown agent state: {raw_state!r}") from exc
        progress = data.get("progress")
        qid = data.get("questionId")
        if qid is None:
            qid = data.get("question_id")
        return cls(
            agent_provider_id=pid,
            state=state,
            reason=(str(data["reason"]) if data.get("reason") is not None else None),
            detail=(str(data["detail"]) if data.get("detail") is not None else None),
            model=(str(data["model"]) if data.get("model") is not None else None),
            progress=float(progress) if isinstance(progress, (int, float)) else None,
            question_id=str(qid) if qid is not None else None,
            raw=dict(data),
        )
