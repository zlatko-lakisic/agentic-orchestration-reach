"""AO Reach — Python client for agentic-orchestration session overlays + MCP tunnels.

Import submodules directly (e.g. ``ao_reach.connection_config``) to avoid pulling
heavy deps like aiohttp during Home Assistant config-flow discovery.
"""

from __future__ import annotations

__version__ = "0.15.0"

__all__ = [
    "EmptySessionMcpBootstrap",
    "LocalMcpHost",
    "McpSessionSpec",
    "McpSessionTransport",
    "OverlayPacker",
    "ReachCatalog",
    "ReachCatalogClient",
    "ReachCatalogEntry",
    "ReachCatalogSecretField",
    "ReachConnectionConfig",
    "ReachMtlsConfig",
    "ReachMtlsEnroller",
    "ReachMtlsMaterial",
    "ReachRunError",
    "ReachRunStatus",
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


def __getattr__(name: str):
    """Lazy attribute access so light imports stay dependency-free."""
    mapping = {
        "ReachCatalog": (".catalog_client", "ReachCatalog"),
        "ReachCatalogClient": (".catalog_client", "ReachCatalogClient"),
        "ReachCatalogEntry": (".catalog_client", "ReachCatalogEntry"),
        "ReachCatalogSecretField": (".catalog_client", "ReachCatalogSecretField"),
        "ReachConnectionConfig": (".connection_config", "ReachConnectionConfig"),
        "ReachRunError": (".run_status", "ReachRunError"),
        "ReachRunStatus": (".run_status", "ReachRunStatus"),
        "ensure_reach_identity": (".connection_config", "ensure_reach_identity"),
        "normalize_reach_app_id": (".connection_config", "normalize_reach_app_id"),
        "reach_ws_uri": (".connection_config", "reach_ws_uri"),
        "bare_agent_id": (".ids", "bare_agent_id"),
        "to_client_agent_id": (".ids", "to_client_agent_id"),
        "LocalMcpHost": (".local_mcp_host", "LocalMcpHost"),
        "EmptySessionMcpBootstrap": (".mcp_bootstrap", "EmptySessionMcpBootstrap"),
        "SessionMcpBootstrap": (".mcp_bootstrap", "SessionMcpBootstrap"),
        "SessionMcpBootstrapResult": (".mcp_bootstrap", "SessionMcpBootstrapResult"),
        "McpSessionSpec": (".mcp_session_spec", "McpSessionSpec"),
        "McpSessionTransport": (".mcp_session_spec", "McpSessionTransport"),
        "session_tunnel_mcp_entry": (".mcp_session_spec", "session_tunnel_mcp_entry"),
        "ReachMtlsConfig": (".mtls", "ReachMtlsConfig"),
        "ReachMtlsMaterial": (".mtls", "ReachMtlsMaterial"),
        "load_reach_mtls_material": (".mtls", "load_reach_mtls_material"),
        "persist_reach_mtls_material": (".mtls", "persist_reach_mtls_material"),
        "ReachMtlsEnroller": (".mtls_enroller", "ReachMtlsEnroller"),
        "OverlayPacker": (".overlay_packer", "OverlayPacker"),
        "SessionOverlayPack": (".overlay_packer", "SessionOverlayPack"),
        "SessionBridge": (".session_bridge", "SessionBridge"),
        "SessionBridgeState": (".session_bridge", "SessionBridgeState"),
        "SpeechCapabilities": (".speech_client", "SpeechCapabilities"),
        "SpeechClient": (".speech_client", "SpeechClient"),
        "TranscriptionResult": (".speech_client", "TranscriptionResult"),
    }
    if name not in mapping:
        raise AttributeError(f"module {__name__!r} has no attribute {name!r}")
    module_name, attr = mapping[name]
    import importlib

    mod = importlib.import_module(module_name, __name__)
    value = getattr(mod, attr)
    globals()[name] = value
    return value
