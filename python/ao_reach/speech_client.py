"""Speech sidecars advertised on AO hello."""

from __future__ import annotations

import json
from dataclasses import dataclass
from typing import Any

import aiohttp


@dataclass
class SpeechCapabilities:
    stt_base_url: str
    tts_base_url: str
    transcribe_path: str = "/v1/audio/transcriptions"
    speech_path: str = "/v1/audio/speech"
    openai_compatible: bool = True
    auth_bearer: bool = False

    @classmethod
    def try_parse(cls, raw: object) -> SpeechCapabilities | None:
        if not isinstance(raw, dict):
            return None
        if raw.get("enabled") is False:
            return None
        stt = str(raw.get("sttBaseUrl") or "").strip().rstrip("/")
        tts = str(raw.get("ttsBaseUrl") or "").strip().rstrip("/")
        if not stt or not tts:
            return None
        auth = str(raw.get("auth") or "").lower()
        return cls(
            stt_base_url=stt,
            tts_base_url=tts,
            transcribe_path=(str(raw.get("transcribePath") or "").strip() or "/v1/audio/transcriptions"),
            speech_path=(str(raw.get("speechPath") or "").strip() or "/v1/audio/speech"),
            openai_compatible=raw.get("openaiCompatible") is not False,
            auth_bearer=auth == "bearer",
        )

    def with_overrides(
        self, *, stt_base_url: str | None = None, tts_base_url: str | None = None
    ) -> SpeechCapabilities:
        stt = (stt_base_url or "").strip().rstrip("/") or None
        tts = (tts_base_url or "").strip().rstrip("/") or None
        if stt is None and tts is None:
            return self
        return SpeechCapabilities(
            stt_base_url=stt or self.stt_base_url,
            tts_base_url=tts or self.tts_base_url,
            transcribe_path=self.transcribe_path,
            speech_path=self.speech_path,
            openai_compatible=self.openai_compatible,
            auth_bearer=self.auth_bearer,
        )

    @property
    def transcribe_uri(self) -> str:
        return f"{self.stt_base_url}{self.transcribe_path}"

    @property
    def speech_uri(self) -> str:
        return f"{self.tts_base_url}{self.speech_path}"


@dataclass
class TranscriptionResult:
    text: str
    language: str | None = None
    language_probability: float | None = None
    avg_logprob: float | None = None
    no_speech_prob: float | None = None
    compression_ratio: float | None = None
    duration_sec: float | None = None

    @property
    def is_empty(self) -> bool:
        return not self.text.strip()

    @classmethod
    def from_json(cls, data: dict[str, Any]) -> TranscriptionResult:
        if "text" not in data:
            raise RuntimeError("STT response missing text field")

        def num(*keys: str) -> float | None:
            for k in keys:
                v = data.get(k)
                if isinstance(v, (int, float)):
                    return float(v)
                if isinstance(v, str):
                    try:
                        return float(v.strip())
                    except ValueError:
                        pass
            return None

        def s(*keys: str) -> str | None:
            for k in keys:
                v = data.get(k)
                if v is None:
                    continue
                t = str(v).strip()
                if t:
                    return t
            return None

        return cls(
            text=str(data["text"]),
            language=s("language"),
            language_probability=num("language_probability", "languageProbability"),
            avg_logprob=num("avg_logprob", "avgLogprob"),
            no_speech_prob=num("no_speech_prob", "noSpeechProb"),
            compression_ratio=num("compression_ratio", "compressionRatio"),
            duration_sec=num("duration", "duration_sec", "durationSec"),
        )


class SpeechClient:
    def __init__(
        self,
        capabilities: SpeechCapabilities,
        *,
        headers: dict[str, str] | None = None,
        speech_token: str | None = None,
        session: aiohttp.ClientSession | None = None,
    ) -> None:
        self.capabilities = capabilities
        self.headers = dict(headers or {})
        self.speech_token = speech_token
        self._session = session
        self._owned = session is None

    def _auth_headers(self) -> dict[str, str]:
        out: dict[str, str] = {}
        token = (self.speech_token or "").strip()
        if token:
            out["Authorization"] = f"Bearer {token}"
        elif self.capabilities.auth_bearer:
            existing = self.headers.get("Authorization") or self.headers.get("authorization")
            if existing and existing.strip():
                out["Authorization"] = existing.strip()
        return out

    async def _ensure_session(self) -> aiohttp.ClientSession:
        if self._session is None or self._session.closed:
            self._session = aiohttp.ClientSession()
            self._owned = True
        return self._session

    async def transcribe(
        self, audio_bytes: bytes, *, filename: str = "audio.wav", language: str = "en"
    ) -> str:
        result = await self.transcribe_detailed(
            audio_bytes, filename=filename, language=language
        )
        return result.text

    async def transcribe_detailed(
        self, audio_bytes: bytes, *, filename: str = "audio.wav", language: str = "en"
    ) -> TranscriptionResult:
        session = await self._ensure_session()
        form = aiohttp.FormData()
        form.add_field("language", language)
        form.add_field(
            "file",
            audio_bytes,
            filename=filename,
            content_type="audio/wav",
        )
        async with session.post(
            self.capabilities.transcribe_uri,
            data=form,
            headers=self._auth_headers(),
        ) as res:
            body = await res.read()
            if res.status < 200 or res.status >= 300:
                raise RuntimeError(
                    f"STT failed HTTP {res.status}: {body.decode('utf-8', errors='replace')}"
                )
            data = json.loads(body.decode("utf-8"))
            if not isinstance(data, dict):
                raise RuntimeError("STT response missing text field")
            return TranscriptionResult.from_json(data)

    async def synthesize(self, text: str, *, voice: str | None = None) -> bytes:
        session = await self._ensure_session()
        payload: dict[str, Any] = {"text": text, "input": text}
        if voice and voice.strip():
            payload["voice"] = voice.strip()
        headers = {
            **self._auth_headers(),
            "Content-Type": "application/json",
            "Accept": "audio/wav",
        }
        async with session.post(
            self.capabilities.speech_uri, json=payload, headers=headers
        ) as res:
            body = await res.read()
            if res.status < 200 or res.status >= 300:
                raise RuntimeError(
                    f"TTS failed HTTP {res.status}: {body.decode('utf-8', errors='replace')}"
                )
            return body

    async def close(self) -> None:
        if self._owned and self._session and not self._session.closed:
            await self._session.close()
