"""Structured run progress / error updates from AO (`type: status` / `error`)."""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any


@dataclass(frozen=True)
class ReachRunStatus:
    """One status frame during chat / direct_agent.

    ``message`` is user-friendly and safe to stream to the end user as-is.
    """

    processing: bool
    phase: str
    message: str
    detail: str | None = None
    agent_provider_id: str | None = None
    step: int | None = None
    step_count: int | None = None
    code: str | None = None
    question_id: str | None = None
    run_id: str | None = None
    queue_phase: str | None = None
    queue_position: int | None = None
    queue_length: int | None = None
    queue_priority: int | None = None
    queue_priority_label: str | None = None
    elapsed_ms: float | None = None
    raw: dict[str, Any] = field(default_factory=dict)

    @classmethod
    def from_json(cls, data: dict[str, Any]) -> ReachRunStatus:
        step = data.get("step")
        step_count = data.get("stepCount", data.get("step_count"))
        queue_position = data.get("queuePosition", data.get("queue_position"))
        queue_length = data.get("queueLength", data.get("queue_length"))
        queue_priority = data.get("queuePriority", data.get("queue_priority"))
        elapsed_ms = data.get("elapsedMs", data.get("elapsed_ms"))
        return cls(
            processing=data.get("processing") is True,
            phase=str(data.get("phase") or "info"),
            message=str(data.get("message") or ""),
            detail=(str(data["detail"]) if data.get("detail") is not None else None),
            agent_provider_id=(
                str(data["agentProviderId"])
                if data.get("agentProviderId") is not None
                else (str(data["agent_provider_id"]) if data.get("agent_provider_id") is not None else None)
            ),
            step=int(step) if isinstance(step, (int, float)) else None,
            step_count=int(step_count) if isinstance(step_count, (int, float)) else None,
            code=(str(data["code"]) if data.get("code") is not None else None),
            question_id=(
                str(data["question_id"])
                if data.get("question_id") is not None
                else (str(data["questionId"]) if data.get("questionId") is not None else None)
            ),
            run_id=(
                str(data["run_id"])
                if data.get("run_id") is not None
                else (str(data["runId"]) if data.get("runId") is not None else None)
            ),
            queue_phase=(
                str(data["queuePhase"])
                if data.get("queuePhase") is not None
                else (str(data["queue_phase"]) if data.get("queue_phase") is not None else None)
            ),
            queue_position=int(queue_position) if isinstance(queue_position, (int, float)) else None,
            queue_length=int(queue_length) if isinstance(queue_length, (int, float)) else None,
            queue_priority=int(queue_priority) if isinstance(queue_priority, (int, float)) else None,
            queue_priority_label=(
                str(data["queuePriorityLabel"])
                if data.get("queuePriorityLabel") is not None
                else (
                    str(data["queue_priority_label"])
                    if data.get("queue_priority_label") is not None
                    else None
                )
            ),
            elapsed_ms=float(elapsed_ms) if isinstance(elapsed_ms, (int, float)) else None,
            raw=dict(data),
        )

    @property
    def is_queued(self) -> bool:
        return self.phase == "queued"

    @property
    def is_preempted(self) -> bool:
        return self.phase == "preempted"

    @property
    def is_error(self) -> bool:
        return self.phase == "error" or (bool(self.code) and not self.processing)


class ReachRunError(RuntimeError):
    """Raised when a run ends with ``ok: false`` or a terminal AO error."""

    def __init__(
        self,
        message: str,
        *,
        code: str | None = None,
        detail: str | None = None,
        question_id: str | None = None,
        run_id: str | None = None,
        phase: str = "error",
    ) -> None:
        super().__init__(message)
        self.message = message
        self.code = code
        self.detail = detail
        self.question_id = question_id
        self.run_id = run_id
        self.phase = phase

    @property
    def processing(self) -> bool:
        return False

    @classmethod
    def from_status(cls, status: ReachRunStatus) -> ReachRunError:
        return cls(
            status.message or "AO run failed",
            code=status.code,
            detail=status.detail,
            question_id=status.question_id,
            run_id=status.run_id,
            phase=status.phase,
        )

    def to_status(self) -> ReachRunStatus:
        return ReachRunStatus(
            processing=False,
            phase=self.phase,
            message=self.message,
            detail=self.detail,
            code=self.code,
            question_id=self.question_id,
            run_id=self.run_id,
        )
