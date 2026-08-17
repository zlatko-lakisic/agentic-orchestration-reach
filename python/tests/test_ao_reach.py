"""Unit tests for Python ao_reach."""

from __future__ import annotations

import asyncio
from pathlib import Path

import yaml

from ao_reach.connection_config import normalize_reach_app_id, reach_ws_uri
from ao_reach.ids import bare_agent_id, to_client_agent_id
from ao_reach.overlay_packer import OverlayPacker
from ao_reach.run_status import ReachRunError
from ao_reach.session_bridge import SessionBridge, SessionBridgeState
from ao_reach.speech_client import SpeechCapabilities, TranscriptionResult


def test_normalize_app_id() -> None:
    assert normalize_reach_app_id("ComStar-HA") == "comstar-ha"


def test_reach_ws_uri() -> None:
    assert reach_ws_uri("https://10.0.10.16:8765/") == "wss://10.0.10.16:8765/ws"
    assert reach_ws_uri("http://127.0.0.1:8765") == "ws://127.0.0.1:8765/ws"


def test_client_ids() -> None:
    assert to_client_agent_id("voice_responder") == "client.voice_responder"
    assert to_client_agent_id("client.voice_responder") == "client.voice_responder"
    assert bare_agent_id("client.voice_responder") == "voice_responder"


def test_speech_capabilities_parse() -> None:
    caps = SpeechCapabilities.try_parse(
        {
            "enabled": True,
            "sttBaseUrl": "http://10.0.10.16:8090/",
            "ttsBaseUrl": "http://10.0.10.16:8091/",
            "auth": "bearer",
        }
    )
    assert caps is not None
    assert caps.stt_base_url == "http://10.0.10.16:8090"
    assert caps.auth_bearer is True
    assert SpeechCapabilities.try_parse({"enabled": False}) is None


def test_transcription_result() -> None:
    r = TranscriptionResult.from_json({"text": "hello", "avg_logprob": -0.2})
    assert r.text == "hello"
    assert r.avg_logprob == -0.2


def test_sanitize_tunnel_body() -> None:
    raw = b'{"type": ["string", "array"], "x": 1}'
    out = SessionBridge.sanitize_mcp_tunnel_body(raw)
    assert b'"type":"string"' in out


def _image() -> dict[str, object]:
    return {"mimeType": "image/jpeg", "dataBase64": "AAAA", "name": "gate_1.jpg"}


async def _capture_payload(bridge: SessionBridge, coro) -> dict[str, object]:
    """Run one bridge call far enough to capture the WebSocket payload it sends."""
    sent: dict[str, object] = {}

    async def fake_send(payload: dict[str, object]) -> None:
        sent.update(payload)
        raise _StopAfterSend

    bridge.state = SessionBridgeState.ACTIVE
    bridge._ws = object()  # only checked for None
    bridge._send = fake_send  # type: ignore[method-assign]
    try:
        await coro(bridge)
    except _StopAfterSend:
        pass
    return sent


class _StopAfterSend(Exception):
    """Abort the call once the payload is on the wire — no engine in this test."""


def test_direct_agent_sends_images_when_given() -> None:
    payload = asyncio.run(
        _capture_payload(
            SessionBridge(),
            lambda b: b.direct_agent(
                agent_provider_id="client.vision_scene_analyzer",
                text="who is at the gate",
                images=[_image()],
            ),
        )
    )
    assert payload["type"] == "direct_agent"
    assert payload["images"] == [_image()]


def test_chat_omits_images_when_absent_or_empty() -> None:
    without = asyncio.run(
        _capture_payload(SessionBridge(), lambda b: b.chat(text="why is the sky blue"))
    )
    assert "images" not in without

    empty = asyncio.run(
        _capture_payload(SessionBridge(), lambda b: b.chat(text="hello", images=[]))
    )
    assert "images" not in empty


def test_chat_sends_images_when_given() -> None:
    payload = asyncio.run(
        _capture_payload(
            SessionBridge(),
            lambda b: b.chat(text="classify these", images=[_image(), _image()]),
        )
    )
    assert payload["type"] == "chat"
    assert len(payload["images"]) == 2


def test_overlay_packer(tmp_path: Path) -> None:
    agents = tmp_path / "agent_providers"
    skills = tmp_path / "agent_skills"
    agents.mkdir()
    skills.mkdir()
    (agents / "voice.yaml").write_text(
        yaml.dump(
            {
                "id": "voice_responder",
                "type": "ollama",
                "ollama_host": "workflow",
                "skills": ["spoken_output"],
                "backstory": "base",
            }
        ),
        encoding="utf-8",
    )
    (skills / "spoken.yaml").write_text(
        yaml.dump(
            {
                "id": "spoken_output",
                "content": {"body": "Keep it short."},
                "inject": {"heading": "## Spoken"},
            }
        ),
        encoding="utf-8",
    )
    pack = OverlayPacker().pack(tmp_path)
    assert pack.agents[0]["id"] == "client.voice_responder"
    assert "ollama_host" not in pack.agents[0]
    assert pack.agents[0]["selfcontained"] is False
    assert "## Spoken" in pack.agents[0]["backstory"]
    assert pack.skills[0]["id"] == "client.spoken_output"


def test_cancel_sends_cancel_frame() -> None:
    payload = asyncio.run(
        _capture_payload(SessionBridge(), lambda b: b.cancel("q-1"))
    )
    assert payload == {"type": "cancel", "questionId": "q-1"}


def test_cancel_run_end_raises_cancelled() -> None:
    async def _run() -> None:
        bridge = SessionBridge()
        bridge.state = SessionBridgeState.ACTIVE
        bridge._ws = object()
        sent: list[dict[str, object]] = []

        async def fake_send(payload: dict[str, object]) -> None:
            sent.append(payload)

        bridge._send = fake_send  # type: ignore[method-assign]
        pending = asyncio.create_task(
            bridge.chat(text="hi", question_id="q-cancel", timeout=5.0)
        )
        # Wait until chat registered a pending run and sent the chat frame
        for _ in range(50):
            if any(p.get("type") == "chat" for p in sent):
                break
            await asyncio.sleep(0.01)
        await bridge.cancel("q-cancel")
        assert any(p.get("type") == "cancel" for p in sent)
        bridge._on_run_end(
            {
                "type": "run_end",
                "questionId": "q-cancel",
                "ok": False,
                "code": "cancelled",
                "error": "Cancelled.",
            }
        )
        try:
            await pending
            raise AssertionError("expected ReachRunError")
        except ReachRunError as err:
            assert err.code == "cancelled"

    asyncio.run(_run())
