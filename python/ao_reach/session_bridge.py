"""Remote AO session overlay + MCP tunnel client."""

from __future__ import annotations

import asyncio
import base64
import json
import logging
import re
import ssl
import time
from dataclasses import dataclass, field
from enum import Enum
from typing import Any, Callable

import aiohttp

from .connection_config import ReachConnectionConfig, reach_ws_uri
from .local_mcp_host import LocalMcpHost
from .mcp_bootstrap import EmptySessionMcpBootstrap, SessionMcpBootstrap
from .mtls import ReachMtlsConfig, assert_reach_mtls_uses_tls, load_reach_mtls_material
from .overlay_packer import OverlayPacker
from .speech_client import SpeechCapabilities, SpeechClient

_LOGGER = logging.getLogger(__name__)


class SessionBridgeState(str, Enum):
    IDLE = "idle"
    CONNECTING = "connecting"
    ACTIVE = "active"
    DISCONNECTED = "disconnected"
    FAILED = "failed"


@dataclass
class _PendingDirectRun:
    question_id: str
    stdout: list[str] = field(default_factory=list)
    last_error: str | None = None
    done: asyncio.Future = field(default_factory=lambda: asyncio.get_event_loop().create_future())


class SessionBridge:
    def __init__(
        self,
        *,
        packer: OverlayPacker | None = None,
        mcp_host: LocalMcpHost | None = None,
    ) -> None:
        self._packer = packer or OverlayPacker()
        self._mcp_host = mcp_host or LocalMcpHost()
        self._session: aiohttp.ClientSession | None = None
        self._ws: aiohttp.ClientWebSocketResponse | None = None
        self._reader_task: asyncio.Task | None = None
        self._hello_wait: asyncio.Future | None = None
        self._ack_wait: asyncio.Future | None = None
        self._cleared_wait: asyncio.Future | None = None
        self._pending_runs: dict[str, _PendingDirectRun] = {}
        self._speech_client: SpeechClient | None = None
        self._stopping = False
        self._overlay_refresh_task: asyncio.Task | None = None

        self.state = SessionBridgeState.IDLE
        self.error: str | None = None
        self.session_overlay = False
        self.mcp_tunnel = False
        self.speech: SpeechCapabilities | None = None
        self.registered_agent_ids: list[str] = []
        self.registered_mcp_ids: list[str] = []
        self.expires_at: float | None = None
        self.active_tunnel_bare_ids: list[str] = []
        self.client_mcp_warnings: list[str] = []
        self.register_progress: str | None = None

        self._last_config: ReachConnectionConfig | None = None
        self._last_overlay_root: str | None = None
        self._last_bootstrap: SessionMcpBootstrap = EmptySessionMcpBootstrap()
        self._status_callbacks: list[Callable[[SessionBridge], None]] = []

    @property
    def is_active(self) -> bool:
        return self.state == SessionBridgeState.ACTIVE

    @property
    def mcp_host(self) -> LocalMcpHost:
        return self._mcp_host

    @property
    def speech_client(self) -> SpeechClient | None:
        return self._speech_client

    def on_status(self, callback: Callable[[SessionBridge], None]) -> None:
        self._status_callbacks.append(callback)

    def _emit(self) -> None:
        for cb in list(self._status_callbacks):
            try:
                cb(self)
            except Exception:  # noqa: BLE001
                _LOGGER.exception("status callback failed")

    async def start(
        self,
        *,
        config: ReachConnectionConfig,
        overlay_root: str,
        mcp_bootstrap: SessionMcpBootstrap | None = None,
    ) -> None:
        await self.stop(clear_remote=False)
        self._stopping = False
        bootstrap = mcp_bootstrap or EmptySessionMcpBootstrap()
        if not config.enabled:
            self.state = SessionBridgeState.IDLE
            self.error = None
            self._emit()
            return

        self.state = SessionBridgeState.CONNECTING
        self.error = None
        self.register_progress = None
        self._last_config = config
        self._last_overlay_root = overlay_root
        self._last_bootstrap = bootstrap
        self._emit()

        try:
            await self._connect_and_register(config, overlay_root, bootstrap)
        except Exception as exc:
            self.state = SessionBridgeState.FAILED
            self.error = str(exc)
            await self._cleanup_local(clear_remote=False)
            self._emit()
            raise

    async def _connect_and_register(
        self,
        config: ReachConnectionConfig,
        overlay_root: str,
        mcp_bootstrap: SessionMcpBootstrap,
    ) -> None:
        ssl_ctx = None
        if config.mtls and config.mtls.is_configured:
            assert_reach_mtls_uses_tls(config.base_url)
            material = load_reach_mtls_material(config.mtls)
            from pathlib import Path
            import tempfile

            if material.dir:
                material_path = Path(material.dir)
            else:
                material_path = Path(tempfile.mkdtemp(prefix="ao-reach-mtls-live-"))
                (material_path / "cert.pem").write_text(
                    material.client_cert_pem, encoding="utf-8"
                )
                (material_path / "key.pem").write_text(
                    material.client_key_pem, encoding="utf-8"
                )
                (material_path / "ca.pem").write_text(material.ca_pem, encoding="utf-8")
            ssl_ctx = ssl.create_default_context(cafile=str(material_path / "ca.pem"))
            ssl_ctx.load_cert_chain(
                certfile=str(material_path / "cert.pem"),
                keyfile=str(material_path / "key.pem"),
            )

        connector = aiohttp.TCPConnector(ssl=ssl_ctx) if ssl_ctx else None
        self._session = aiohttp.ClientSession(connector=connector)
        ws_url = reach_ws_uri(config.base_url)
        headers = {k: v for k, v in config.headers.items() if k.lower() != "accept"}

        self._hello_wait = asyncio.get_event_loop().create_future()
        self._ws = await self._session.ws_connect(ws_url, headers=headers, heartbeat=20)
        self._reader_task = asyncio.create_task(self._read_loop())

        hello = await asyncio.wait_for(self._hello_wait, timeout=30)
        self._hello_wait = None
        self.session_overlay = bool(hello.get("sessionOverlay"))
        self.mcp_tunnel = bool(hello.get("mcpTunnel"))
        if not self.session_overlay:
            raise RuntimeError(
                "AO session overlay disabled — set AGENTIC_SERVE_SESSION_OVERLAY=1"
            )

        speech = SpeechCapabilities.try_parse(hello.get("speech"))
        if speech:
            speech = speech.with_overrides(
                stt_base_url=config.speech_stt_base_url_override,
                tts_base_url=config.speech_tts_base_url_override,
            )
            self.speech = speech
            self._speech_client = SpeechClient(
                speech,
                headers=dict(config.headers),
                speech_token=config.speech_token,
            )

        boot = await mcp_bootstrap.prepare(self._mcp_host, mcp_tunnel=self.mcp_tunnel)
        self.client_mcp_warnings = list(boot.warnings)
        self.active_tunnel_bare_ids = list(boot.active_tunnel_bare_ids)

        pack = self._packer.pack(overlay_root, extra_mcps=boot.mcps)
        self._ack_wait = asyncio.get_event_loop().create_future()
        await self._send(
            {
                "type": "session_overlay_register",
                "appId": config.app_id,
                "ttlSeconds": config.ttl_seconds,
                "agents": pack.agents,
                "mcps": pack.mcps,
                "skills": pack.skills,
            }
        )
        ack = await asyncio.wait_for(self._ack_wait, timeout=600)
        self._ack_wait = None
        if ack.get("type") == "session_overlay_denied" or ack.get("type") == "error":
            raise RuntimeError(
                ack.get("message") or ack.get("reason") or "session_overlay_denied"
            )
        self.registered_agent_ids = list(ack.get("agentIds") or pack.agent_ids)
        self.registered_mcp_ids = list(ack.get("mcpIds") or pack.mcp_ids)
        exp = ack.get("expiresAt")
        self.expires_at = float(exp) if isinstance(exp, (int, float)) else None
        self.state = SessionBridgeState.ACTIVE
        self._schedule_overlay_refresh(config)
        self._emit()

    def _schedule_overlay_refresh(self, config: ReachConnectionConfig) -> None:
        if self._overlay_refresh_task:
            self._overlay_refresh_task.cancel()
        ttl = max(60, int(config.ttl_seconds * 0.8))

        async def _loop() -> None:
            while not self._stopping and self.is_active:
                await asyncio.sleep(ttl)
                try:
                    await self.refresh_overlay()
                except Exception:  # noqa: BLE001
                    _LOGGER.exception("overlay refresh failed")

        self._overlay_refresh_task = asyncio.create_task(_loop())

    async def refresh_overlay(self) -> None:
        if not self.is_active or not self._last_config or not self._last_overlay_root:
            raise RuntimeError("Session bridge is not active")
        boot = await self._last_bootstrap.prepare(
            self._mcp_host, mcp_tunnel=self.mcp_tunnel
        )
        pack = self._packer.pack(self._last_overlay_root, extra_mcps=boot.mcps)
        self._ack_wait = asyncio.get_event_loop().create_future()
        await self._send(
            {
                "type": "session_overlay_register",
                "appId": self._last_config.app_id,
                "ttlSeconds": self._last_config.ttl_seconds,
                "agents": pack.agents,
                "mcps": pack.mcps,
                "skills": pack.skills,
            }
        )
        ack = await asyncio.wait_for(self._ack_wait, timeout=600)
        self._ack_wait = None
        if ack.get("type") in ("session_overlay_denied", "error"):
            raise RuntimeError(ack.get("message") or "overlay refresh denied")
        self.registered_agent_ids = list(ack.get("agentIds") or pack.agent_ids)
        self.registered_mcp_ids = list(ack.get("mcpIds") or pack.mcp_ids)
        exp = ack.get("expiresAt")
        self.expires_at = float(exp) if isinstance(exp, (int, float)) else None
        self._emit()

    async def direct_agent(
        self,
        *,
        agent_provider_id: str,
        text: str,
        context: str = "",
        question_id: str | None = None,
        mcp_provider_ids: list[str] | None = None,
        timeout: float = 300.0,
    ) -> dict[str, Any]:
        if not self.is_active or self._ws is None:
            raise RuntimeError("Session bridge is not active — cannot run client.* agents")
        prefix = self._last_config.question_id_prefix if self._last_config else "reach"
        qid = (question_id or "").strip() or f"{prefix}-{int(time.time() * 1_000_000)}"
        if qid in self._pending_runs:
            raise RuntimeError(f"direct_agent already in flight for questionId={qid}")
        loop = asyncio.get_event_loop()
        pending = _PendingDirectRun(question_id=qid, done=loop.create_future())
        self._pending_runs[qid] = pending
        payload: dict[str, Any] = {
            "type": "direct_agent",
            "agentProviderId": agent_provider_id,
            "text": text,
            "context": context,
            "questionId": qid,
        }
        if mcp_provider_ids:
            payload["mcpProviderIds"] = mcp_provider_ids
        await self._send(payload)
        try:
            return await asyncio.wait_for(pending.done, timeout=timeout)
        except TimeoutError:
            self._pending_runs.pop(qid, None)
            raise TimeoutError(f"direct_agent timed out for {agent_provider_id} ({qid})") from None

    async def _read_loop(self) -> None:
        assert self._ws is not None
        try:
            async for msg in self._ws:
                if msg.type == aiohttp.WSMsgType.TEXT:
                    self._on_message(msg.data)
                elif msg.type in (aiohttp.WSMsgType.CLOSED, aiohttp.WSMsgType.ERROR):
                    break
        except Exception:  # noqa: BLE001
            if not self._stopping:
                _LOGGER.exception("Reach WS read loop error")
        finally:
            if not self._stopping:
                self.state = SessionBridgeState.DISCONNECTED
                self.error = "WebSocket closed"
                self._emit()

    def _on_message(self, raw: str | bytes) -> None:
        try:
            msg = json.loads(raw)
        except json.JSONDecodeError:
            return
        if not isinstance(msg, dict):
            return
        typ = str(msg.get("type") or "")
        if typ == "hello":
            if self._hello_wait and not self._hello_wait.done():
                self._hello_wait.set_result(msg)
        elif typ == "session_overlay_ack":
            if self._ack_wait and not self._ack_wait.done():
                self._ack_wait.set_result(msg)
        elif typ in ("session_overlay_denied",):
            if self._ack_wait and not self._ack_wait.done():
                self._ack_wait.set_result(msg)
        elif typ == "session_overlay_cleared":
            if self._cleared_wait and not self._cleared_wait.done():
                self._cleared_wait.set_result(msg)
        elif typ == "chunk":
            if self._ack_wait and not self._ack_wait.done():
                text = str(msg.get("text") or "").strip()
                if text:
                    self.register_progress = re.sub(r"^\(engine\)\s*", "", text)
                    self._emit()
            self._on_run_chunk(msg)
        elif typ == "run_end":
            self._on_run_end(msg)
        elif typ == "error":
            if self._ack_wait and not self._ack_wait.done():
                self._ack_wait.set_result(msg)
            elif self._hello_wait and not self._hello_wait.done():
                self._hello_wait.set_exception(
                    RuntimeError(str(msg.get("message") or "AO error"))
                )
            else:
                self._on_run_error(msg)
        elif typ == "mcp_tunnel_request":
            asyncio.create_task(self._handle_tunnel_request(msg))

    def _on_run_chunk(self, msg: dict[str, Any]) -> None:
        qid = msg.get("question_id") or msg.get("questionId")
        if not qid:
            return
        run = self._pending_runs.get(str(qid))
        if not run:
            return
        if str(msg.get("stream") or "stdout") == "stdout":
            run.stdout.append(str(msg.get("text") or ""))

    def _on_run_error(self, msg: dict[str, Any]) -> None:
        qid = msg.get("question_id") or msg.get("questionId")
        if not qid:
            return
        run = self._pending_runs.get(str(qid))
        if run:
            run.last_error = str(msg.get("message") or "AO error")

    def _on_run_end(self, msg: dict[str, Any]) -> None:
        qid = msg.get("question_id") or msg.get("questionId")
        if not qid:
            return
        run = self._pending_runs.pop(str(qid), None)
        if not run or run.done.done():
            return
        text = "".join(run.stdout)
        fallback = str(msg.get("text") or "")
        ok = msg.get("ok") is True
        err = msg.get("error") or run.last_error
        if not ok:
            run.done.set_exception(
                RuntimeError(err if err else "direct_agent failed (run_end ok=false)")
            )
            return
        run.done.set_result(
            {
                "ok": True,
                "text": text if text else fallback,
                "elapsedMs": msg.get("elapsedMs"),
                "questionId": str(qid),
            }
        )

    async def _handle_tunnel_request(self, msg: dict[str, Any]) -> None:
        request_id = str(msg.get("requestId") or "")
        if not request_id:
            return
        if not self._mcp_host.is_running:
            await self._send(
                {
                    "type": "mcp_tunnel_response",
                    "requestId": request_id,
                    "status": 503,
                    "headers": {"content-type": "application/json"},
                    "bodyBase64": base64.b64encode(
                        json.dumps({"error": "local client MCP is not running"}).encode()
                    ).decode(),
                }
            )
            return
        tunnel_path = str(msg.get("tunnelPath") or "")
        if not self._mcp_host.is_alias_running(tunnel_path):
            await self._send(
                {
                    "type": "mcp_tunnel_response",
                    "requestId": request_id,
                    "status": 404,
                    "headers": {"content-type": "application/json"},
                    "bodyBase64": base64.b64encode(
                        json.dumps({"error": f"unknown tunnelPath {tunnel_path}"}).encode()
                    ).decode(),
                }
            )
            return
        try:
            method = str(msg.get("method") or "POST").upper()
            path = str(msg.get("path") or "/mcp")
            if not path or path == "/":
                path = "/mcp"
            headers_raw = msg.get("headers") or {}
            headers = {str(k): str(v) for k, v in headers_raw.items()} if isinstance(headers_raw, dict) else {}
            body_b64 = str(msg.get("bodyBase64") or "")
            body = base64.b64decode(body_b64) if body_b64 else b""
            status, out_headers, out_body = await self._mcp_host.forward(
                alias=tunnel_path, method=method, path=path, headers=headers, body=body
            )
            sanitized = self.sanitize_mcp_tunnel_body(out_body)
            await self._send(
                {
                    "type": "mcp_tunnel_response",
                    "requestId": request_id,
                    "status": status,
                    "headers": out_headers,
                    "bodyBase64": base64.b64encode(sanitized).decode(),
                }
            )
        except Exception as exc:  # noqa: BLE001
            _LOGGER.warning("mcp_tunnel fail alias=%s err=%s", tunnel_path, exc)
            await self._send(
                {
                    "type": "mcp_tunnel_response",
                    "requestId": request_id,
                    "status": 502,
                    "headers": {"content-type": "application/json"},
                    "bodyBase64": base64.b64encode(
                        json.dumps({"error": f"tunnel proxy failed: {exc}"}).encode()
                    ).decode(),
                }
            )

    @staticmethod
    def sanitize_mcp_tunnel_body(body: bytes) -> bytes:
        if not body:
            return body
        text = body.decode("utf-8", errors="replace")
        if '"type"' not in text or "array" not in text:
            return body
        fixed = re.sub(
            r'"type"\s*:\s*\[\s*"string"\s*,\s*"array"\s*\]',
            '"type":"string"',
            text,
        )
        fixed = re.sub(
            r'"type"\s*:\s*\[\s*"array"\s*,\s*"string"\s*\]',
            '"type":"string"',
            fixed,
        )
        return fixed.encode("utf-8") if fixed != text else body

    async def _send(self, payload: dict[str, Any]) -> None:
        if self._ws is None or self._ws.closed:
            return
        await self._ws.send_str(json.dumps(payload))

    async def stop(self, *, clear_remote: bool = True) -> None:
        self._stopping = True
        await self._cleanup_local(clear_remote=clear_remote)
        self.state = SessionBridgeState.IDLE
        self.registered_agent_ids = []
        self.registered_mcp_ids = []
        self.expires_at = None
        self.active_tunnel_bare_ids = []
        self.client_mcp_warnings = []
        self.speech = None
        self.error = None
        self._emit()

    async def _cleanup_local(self, *, clear_remote: bool) -> None:
        if self._overlay_refresh_task:
            self._overlay_refresh_task.cancel()
            self._overlay_refresh_task = None
        if clear_remote and self._ws and not self._ws.closed:
            try:
                self._cleared_wait = asyncio.get_event_loop().create_future()
                await self._send({"type": "session_overlay_clear"})
                await asyncio.wait_for(self._cleared_wait, timeout=5)
            except Exception:  # noqa: BLE001
                pass
            finally:
                self._cleared_wait = None
        if self._reader_task:
            self._reader_task.cancel()
            self._reader_task = None
        if self._ws and not self._ws.closed:
            await self._ws.close()
        self._ws = None
        if self._speech_client:
            await self._speech_client.close()
            self._speech_client = None
        await self._mcp_host.stop_all()
        if self._session and not self._session.closed:
            await self._session.close()
        self._session = None
        for run in list(self._pending_runs.values()):
            if not run.done.done():
                run.done.set_exception(RuntimeError("session stopped"))
        self._pending_runs.clear()


async def probe_health(base_url: str, mtls: ReachMtlsConfig | None = None, timeout: float = 10.0) -> dict[str, Any]:
    """GET {base}/health with optional client cert (Comstar ao_mtls probe)."""
    base = base_url.rstrip("/")
    ssl_ctx = None
    if mtls and mtls.is_configured:
        assert_reach_mtls_uses_tls(base)
        material = load_reach_mtls_material(mtls)
        from pathlib import Path

        if material.dir:
            ssl_ctx = ssl.create_default_context(cafile=str(Path(material.dir) / "ca.pem"))
            ssl_ctx.load_cert_chain(
                certfile=str(Path(material.dir) / "cert.pem"),
                keyfile=str(Path(material.dir) / "key.pem"),
            )
    connector = aiohttp.TCPConnector(ssl=ssl_ctx) if ssl_ctx else None
    async with aiohttp.ClientSession(connector=connector) as session:
        async with session.get(
            f"{base}/health",
            headers={"Accept": "application/json"},
            timeout=aiohttp.ClientTimeout(total=timeout),
        ) as res:
            body = await res.text()
            ok = 200 <= res.status < 300
            return {
                "ok": ok,
                "action": "probe",
                "status_code": res.status,
                "body_preview": body[:200],
            }
