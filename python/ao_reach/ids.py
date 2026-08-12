"""Map bare overlay / catalog ids ↔ session-overlay ``client.*`` ids."""

CLIENT_ID_PREFIX = "client."

CLIENT_FILESYSTEM_MCP_ID = "client.filesystem_local"
FILESYSTEM_TUNNEL_ALIAS = "filesystem"
EMAIL_GMAIL_TUNNEL_ALIAS = "email_gmail"
CALENDAR_GOOGLE_TUNNEL_ALIAS = "calendar_google"
CLIENT_EMAIL_GMAIL_MCP_ID = "client.email_gmail"
CLIENT_CALENDAR_GOOGLE_MCP_ID = "client.calendar_google"


def to_client_agent_id(bare_id: str) -> str:
    id_ = bare_id.strip()
    if not id_:
        return id_
    if id_.startswith(CLIENT_ID_PREFIX):
        return id_
    return f"{CLIENT_ID_PREFIX}{id_}"


def bare_agent_id(agent_id: str) -> str:
    id_ = agent_id.strip()
    if id_.startswith(CLIENT_ID_PREFIX):
        return id_[len(CLIENT_ID_PREFIX) :]
    return id_


def resolve_product_agent_id(bare_id: str, *, session_overlay_active: bool) -> str:
    return to_client_agent_id(bare_id) if session_overlay_active else bare_id


def resolve_session_mcp_id(
    bare_or_client_id: str,
    *,
    session_overlay_active: bool,
    registered_mcp_ids: list[str],
) -> str:
    bare = bare_agent_id(bare_or_client_id)
    if not session_overlay_active:
        return bare
    client = to_client_agent_id(bare)
    if client in registered_mcp_ids:
        return client
    return bare
