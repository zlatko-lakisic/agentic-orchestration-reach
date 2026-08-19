import 'local_mcp_host.dart';

import 'connection_config.dart';

/// Product-supplied preparation of local MCP processes + overlay MCP entries.
///
/// Reach starts the WebSocket and registers agents; apps decide which client
/// tools to spawn and which MCP dicts to attach to the overlay.
abstract class SessionMcpBootstrap {
  Future<SessionMcpBootstrapResult> prepare(
    LocalMcpHost host, {
    required bool mcpTunnel,
    ReachConnectionConfig? config,
    bool customToolSandbox = false,
  });
}

/// Result of [SessionMcpBootstrap.prepare].
class SessionMcpBootstrapResult {
  const SessionMcpBootstrapResult({
    this.mcps = const [],
    this.warnings = const [],
    this.filesystemActive = false,
    this.emailGmailActive = false,
    this.calendarGoogleActive = false,
    this.activeTunnelBareIds = const [],
  });

  /// MCP catalog entries for `session_overlay_register` (`client.*` + tunnel/HTTP).
  final List<Map<String, dynamic>> mcps;

  /// Soft-fail notes (optional MCPs skipped); must not fail the whole session.
  final List<String> warnings;

  final bool filesystemActive;
  final bool emailGmailActive;
  final bool calendarGoogleActive;

  /// Bare ids of stdio tunnel MCPs successfully started.
  final List<String> activeTunnelBareIds;

  static const empty = SessionMcpBootstrapResult();
}

/// Bootstrap that registers no client MCPs (agents-only overlay).
class EmptySessionMcpBootstrap implements SessionMcpBootstrap {
  const EmptySessionMcpBootstrap();

  @override
  Future<SessionMcpBootstrapResult> prepare(
    LocalMcpHost host, {
    required bool mcpTunnel,
    ReachConnectionConfig? config,
    bool customToolSandbox = false,
  }) async =>
      SessionMcpBootstrapResult.empty;
}
