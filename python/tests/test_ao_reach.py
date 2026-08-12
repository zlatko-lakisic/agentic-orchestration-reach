"""Unit tests for Python ao_reach."""

from __future__ import annotations

from pathlib import Path

import yaml

from ao_reach.connection_config import normalize_reach_app_id, reach_ws_uri
from ao_reach.ids import bare_agent_id, to_client_agent_id
from ao_reach.overlay_packer import OverlayPacker
from ao_reach.session_bridge import SessionBridge
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
