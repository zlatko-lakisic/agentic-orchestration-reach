"""ReachRunStatus queue field parity tests."""

from __future__ import annotations

from ao_reach.run_status import ReachRunStatus


def test_from_json_parses_queued_frame() -> None:
    status = ReachRunStatus.from_json(
        {
            "type": "status",
            "processing": True,
            "phase": "queued",
            "message": "Waiting in queue — position 2 of 5…",
            "question_id": "q1",
            "run_id": "r1",
            "queuePhase": "execution",
            "queuePosition": 2,
            "queueLength": 5,
            "queuePriority": 75,
            "queuePriorityLabel": "high",
            "elapsedMs": 1200.5,
        }
    )
    assert status.is_queued
    assert status.queue_phase == "execution"
    assert status.queue_position == 2
    assert status.queue_length == 5
    assert status.queue_priority == 75
    assert status.queue_priority_label == "high"
    assert status.elapsed_ms == 1200.5
    assert not status.is_error


def test_from_json_parses_preempted_frame() -> None:
    status = ReachRunStatus.from_json(
        {
            "type": "status",
            "processing": False,
            "phase": "preempted",
            "message": "Stopped to free capacity for a higher-priority request",
            "code": "queue_preempted",
            "question_id": "q2",
        }
    )
    assert status.is_preempted
    assert status.code == "queue_preempted"
    assert status.is_error


def test_chat_sends_priority_when_given() -> None:
    import asyncio

    from ao_reach.session_bridge import SessionBridge, SessionBridgeState

    async def _capture(priority: str | int) -> dict[str, object]:
        sent: dict[str, object] = {}

        async def fake_send(payload: dict[str, object]) -> None:
            sent.update(payload)
            raise _StopAfterSend

        bridge = SessionBridge()
        bridge.state = SessionBridgeState.ACTIVE
        bridge._ws = object()
        bridge._send = fake_send  # type: ignore[method-assign]
        try:
            await bridge.chat(text="hello", question_id="q-pri", priority=priority)
        except _StopAfterSend:
            pass
        return sent

    string_payload = asyncio.run(_capture("realtime"))
    assert string_payload["priority"] == "realtime"

    numeric_payload = asyncio.run(_capture(90))
    assert numeric_payload["priority"] == 90


class _StopAfterSend(Exception):
    pass
