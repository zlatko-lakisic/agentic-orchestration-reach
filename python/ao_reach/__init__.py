"""AO Reach — Python client for agentic-orchestration session overlays + MCP tunnels."""

from .connection_config import (
    ReachConnectionConfig,
    ensure_reach_identity,
    normalize_reach_app_id,
    reach_ws_uri,
)
from .ids import bare_agent_id, to_client_agent_id
from .local_mcp_host import LocalMcpHost
from .mcp_bootstrap import EmptySessionMcpBootstrap, SessionMcpBootstrap, SessionMcpBootstrapResult
from .mcp_session_spec import McpSessionSpec, McpSessionTransport, session_tunnel_mcp_entry
from .mtls import ReachMtlsConfig, ReachMtlsMaterial, load_reach_mtls_material, persist_reach_mtls_material
from .mtls_enroller import ReachMtlsEnroller
from .overlay_packer import OverlayPacker, SessionOverlayPack
from .session_bridge import SessionBridge, SessionBridgeState
from .speech_client import SpeechCapabilities, SpeechClient, TranscriptionResult

__all__ = [
    "EmptySessionMcpBootstrap",
    "LocalMcpHost",
    "McpSessionSpec",
    "McpSessionTransport",
    "OverlayPacker",
    "ReachConnectionConfig",
    "ReachMtlsConfig",
    "ReachMtlsEnroller",
    "ReachMtlsMaterial",
    "SessionBridge",
    "SessionBridgeState",
    "SessionMcpBootstrap",
    "SessionMcpBootstrapResult",
    "SessionOverlayPack",
    "SpeechCapabilities",
    "SpeechClient",
    "TranscriptionResult",
    "bare_agent_id",
    "ensure_reach_identity",
    "load_reach_mtls_material",
    "normalize_reach_app_id",
    "persist_reach_mtls_material",
    "reach_ws_uri",
    "session_tunnel_mcp_entry",
    "to_client_agent_id",
]

__version__ = "0.1.0"
