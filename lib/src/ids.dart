// Map bare overlay / catalog ids ↔ session-overlay `client.*` ids (AO v1.27+).

const String clientIdPrefix = 'client.';

/// Rewrite a disk/catalog agent id for remote session overlay use.
String toClientAgentId(String bareId) {
  final id = bareId.trim();
  if (id.isEmpty) return id;
  if (id.startsWith(clientIdPrefix)) return id;
  return '$clientIdPrefix$id';
}

/// Strip `client.` for local lookups (model hints, status labels).
String bareAgentId(String agentId) {
  final id = agentId.trim();
  if (id.startsWith(clientIdPrefix)) {
    return id.substring(clientIdPrefix.length);
  }
  return id;
}

/// Prefer `client.*` when the remote session overlay is active; else bare disk ids.
String resolveProductAgentId(String bareId, {required bool sessionOverlayActive}) {
  return sessionOverlayActive ? toClientAgentId(bareId) : bareId;
}

/// Map bare catalog id → `client.*` when the session registered that tunnel/HTTP MCP.
String resolveSessionMcpId(
  String bareOrClientId, {
  required bool sessionOverlayActive,
  required List<String> registeredMcpIds,
}) {
  final bare = bareAgentId(bareOrClientId);
  if (!sessionOverlayActive) return bare;
  final client = toClientAgentId(bare);
  if (registeredMcpIds.contains(client)) return client;
  return bare;
}

const String clientFilesystemMcpId = 'client.filesystem_local';

/// Stock AO single-root filesystem MCP (env `FILESYSTEM_MCP_ALLOWED_DIRECTORY`).
const String localFilesystemMcpId = 'filesystem_local';

const String filesystemTunnelAlias = 'filesystem';

const String emailGmailTunnelAlias = 'email_gmail';
const String calendarGoogleTunnelAlias = 'calendar_google';
const String clientEmailGmailMcpId = 'client.email_gmail';
const String clientCalendarGoogleMcpId = 'client.calendar_google';
