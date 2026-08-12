"""Local MCP stdio servers behind mcp-proxy on loopback."""

from __future__ import annotations

import asyncio
import logging
import os
import shutil
import socket
from dataclasses import dataclass, field

import aiohttp

_LOGGER = logging.getLogger(__name__)


@dataclass
class _McpInstance:
    alias: str
    port: int
    process: asyncio.subprocess.Process | None
    log: list[str] = field(default_factory=list)


class LocalMcpHost:
    def __init__(self) -> None:
        self._by_alias: dict[str, _McpInstance] = {}

    @property
    def is_running(self) -> bool:
        return bool(self._by_alias)

    def is_alias_running(self, alias: str) -> bool:
        return alias in self._by_alias

    @property
    def active_aliases(self) -> list[str]:
        return sorted(self._by_alias)

    def mcp_uri_for(self, alias: str) -> str:
        inst = self._by_alias.get(alias)
        if inst is None:
            raise RuntimeError(f"LocalMcpHost alias not started: {alias}")
        return f"http://127.0.0.1:{inst.port}/mcp"

    def attach_loopback_alias(self, alias: str, port: int) -> None:
        self._by_alias[alias] = _McpInstance(alias=alias, port=port, process=None)

    async def start_npx_package(
        self,
        *,
        alias: str,
        package: str,
        extra_env: dict[str, str] | None = None,
        ready_timeout: float = 90.0,
    ) -> None:
        await self.stop_alias(alias)
        npx = shutil.which("npx")
        if not npx:
            raise RuntimeError("npx not found on PATH")
        await self._start_proxy(
            alias=alias,
            npx=npx,
            inner_args=[npx, "-y", package],
            extra_env=extra_env,
            ready_timeout=ready_timeout,
        )

    async def start_python_module(
        self,
        *,
        alias: str,
        module: str,
        extra_env: dict[str, str] | None = None,
        ready_timeout: float = 90.0,
    ) -> None:
        await self.stop_alias(alias)
        npx = shutil.which("npx")
        python = shutil.which("python") or shutil.which("python3")
        if not npx or not python:
            raise RuntimeError("npx and python required for python MCP module")
        await self._start_proxy(
            alias=alias,
            npx=npx,
            inner_args=[python, "-m", module],
            extra_env=extra_env,
            ready_timeout=ready_timeout,
        )

    async def start_stdio_command(
        self,
        *,
        alias: str,
        command: list[str],
        extra_env: dict[str, str] | None = None,
        ready_timeout: float = 90.0,
    ) -> None:
        if not command:
            raise RuntimeError("start_stdio_command requires a non-empty command")
        await self.stop_alias(alias)
        npx = shutil.which("npx")
        if not npx:
            raise RuntimeError("npx not found on PATH")
        await self._start_proxy(
            alias=alias,
            npx=npx,
            inner_args=command,
            extra_env=extra_env,
            ready_timeout=ready_timeout,
        )

    async def _start_proxy(
        self,
        *,
        alias: str,
        npx: str,
        inner_args: list[str],
        extra_env: dict[str, str] | None,
        ready_timeout: float,
    ) -> None:
        port = self._pick_free_port()
        shell_cmd = " ".join(_shell_quote(a) for a in inner_args)
        args = [
            "-y",
            "mcp-proxy@5.12.5",
            "--host",
            "127.0.0.1",
            "--port",
            str(port),
            "--server",
            "stream",
            "--stateless",
            "--streamEndpoint",
            "/mcp",
            "--shell",
            shell_cmd,
        ]
        env = {**os.environ, **(extra_env or {})}
        process = await asyncio.create_subprocess_exec(
            npx,
            *args,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            env=env,
        )
        inst = _McpInstance(alias=alias, port=port, process=process)
        self._by_alias[alias] = inst
        asyncio.create_task(self._drain(inst, process.stdout))
        asyncio.create_task(self._drain(inst, process.stderr))
        try:
            await self._wait_healthy(inst, timeout=ready_timeout)
        except Exception:
            await self.stop_alias(alias)
            raise

    async def _drain(self, inst: _McpInstance, stream: asyncio.StreamReader | None) -> None:
        if stream is None:
            return
        while True:
            line = await stream.readline()
            if not line:
                break
            text = line.decode("utf-8", errors="replace")
            inst.log.append(text)
            if len(inst.log) > 200:
                inst.log = inst.log[-100:]

    async def _wait_healthy(self, inst: _McpInstance, *, timeout: float) -> None:
        deadline = asyncio.get_event_loop().time() + timeout
        url = f"http://127.0.0.1:{inst.port}/mcp"
        async with aiohttp.ClientSession() as session:
            while asyncio.get_event_loop().time() < deadline:
                if inst.process and inst.process.returncode is not None:
                    raise RuntimeError(
                        f"MCP proxy exited early for {inst.alias}: {''.join(inst.log[-20:])}"
                    )
                try:
                    async with session.get(url, timeout=aiohttp.ClientTimeout(total=2)) as res:
                        if res.status < 500:
                            return
                except Exception:
                    pass
                await asyncio.sleep(0.5)
        raise TimeoutError(f"MCP alias {inst.alias} not healthy within {timeout}s")

    async def forward(
        self,
        *,
        alias: str,
        method: str,
        path: str,
        headers: dict[str, str],
        body: bytes,
    ) -> tuple[int, dict[str, str], bytes]:
        inst = self._by_alias.get(alias)
        if inst is None:
            raise RuntimeError(f"unknown tunnel alias {alias}")
        if not path or path == "/":
            path = "/mcp"
        url = f"http://127.0.0.1:{inst.port}{path}"
        async with aiohttp.ClientSession() as session:
            async with session.request(method, url, headers=headers, data=body) as res:
                out_headers = {k: v for k, v in res.headers.items()}
                return res.status, out_headers, await res.read()

    async def stop_alias(self, alias: str) -> None:
        inst = self._by_alias.pop(alias, None)
        if inst is None:
            return
        if inst.process and inst.process.returncode is None:
            inst.process.terminate()
            try:
                await asyncio.wait_for(inst.process.wait(), timeout=5)
            except TimeoutError:
                inst.process.kill()

    async def stop_all(self) -> None:
        for alias in list(self._by_alias):
            await self.stop_alias(alias)

    @staticmethod
    def _pick_free_port() -> int:
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
            sock.bind(("127.0.0.1", 0))
            return int(sock.getsockname()[1])


def _shell_quote(arg: str) -> str:
    if not arg:
        return "''"
    if all(c.isalnum() or c in "@%_+-=:,./" for c in arg):
        return arg
    return "'" + arg.replace("'", "'\"'\"'") + "'"
