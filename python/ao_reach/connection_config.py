"""Connection settings for AO Reach."""

from __future__ import annotations

import os
import random
import re
from dataclasses import dataclass, field, replace
from typing import TYPE_CHECKING
from urllib.parse import urlparse, urlunparse

if TYPE_CHECKING:
    from .mtls import ReachMtlsConfig

REACH_APP_ID_PATTERN = re.compile(r"^[a-z][a-z0-9_-]{1,63}$")


def normalize_reach_app_id(raw: str) -> str:
    app_id = raw.strip().lower()
    if not app_id:
        raise ValueError(
            "ReachConnectionConfig.appId is required "
            "(clients must advertise a stable id such as 'comstar-ha')"
        )
    if not REACH_APP_ID_PATTERN.match(app_id):
        raise ValueError(f"appId must match {REACH_APP_ID_PATTERN.pattern}")
    return app_id


@dataclass
class ReachConnectionConfig:
    base_url: str
    app_id: str
    headers: dict[str, str] = field(default_factory=dict)
    enabled: bool = True
    ttl_seconds: int = 3600
    question_id_prefix: str = "reach"
    max_reconnect_attempts: int = 1
    speech_token: str | None = None
    speech_stt_base_url_override: str | None = None
    speech_tts_base_url_override: str | None = None
    mtls: ReachMtlsConfig | None = None

    def __post_init__(self) -> None:
        self.app_id = normalize_reach_app_id(self.app_id)
        self.base_url = self.base_url.rstrip("/")
        self.headers = dict(self.headers)

    def copy_with(self, **kwargs: object) -> ReachConnectionConfig:
        return replace(self, **kwargs)  # type: ignore[arg-type]


def ensure_reach_identity(
    *,
    user_name: str,
    session_id: str,
    default_user: str = "reach",
    session_prefix: str = "reach",
) -> tuple[str, str]:
    user = user_name.strip()
    session = session_id.strip()
    if not user:
        user = os.environ.get("USER") or os.environ.get("USERNAME") or default_user
    if not session:
        session = f"{session_prefix}-{random.randrange(0x7FFFFFFF):x}"
    return user, session


def reach_ws_uri(base_url: str) -> str:
    parsed = urlparse(base_url.rstrip("/"))
    scheme = "wss" if parsed.scheme == "https" else "ws"
    return urlunparse((scheme, parsed.netloc, "/ws", "", "", ""))
