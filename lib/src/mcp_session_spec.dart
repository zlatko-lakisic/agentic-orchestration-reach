import 'ids.dart';

/// How a Tools MCP is exposed to remote AO via session overlay.
enum McpSessionTransport {
  /// Local stdio MCP behind mcp-proxy → `tunnel://session-mcp/<alias>`.
  stdioTunnel,

  /// Direct `streamable_http` URL registered on the session overlay (no local process).
  httpUrl,
}

/// One MCP that can be registered as `client.<bareId>` on remote AO.
class McpSessionSpec {
  const McpSessionSpec({
    required this.bareId,
    required this.alias,
    required this.transport,
    required this.description,
    this.npxPackage,
    this.pythonModule,
    this.envKeys = const [],
    this.httpUrlFromEnv,
  });

  final String bareId;
  final String alias;
  final McpSessionTransport transport;
  final String description;

  /// npm package for `npx -y <package>` (stdioTunnel).
  final String? npxPackage;

  /// Python `-m` module (stdioTunnel), e.g. `mcp_server_fetch`.
  final String? pythonModule;

  /// Env keys to copy into the stdio process.
  final List<String> envKeys;

  /// Build HTTP URL from resolved env (httpUrl transport).
  final String? Function(Map<String, String> env)? httpUrlFromEnv;

  String get clientId => toClientAgentId(bareId);
}

Map<String, dynamic> sessionHttpMcpEntry({
  required String clientId,
  required String description,
  required String url,
}) {
  return {
    'id': clientId,
    'description': description,
    'streamable_http': {
      'url': url,
      'headers': <String, String>{
        'Accept': 'application/json, text/event-stream',
      },
    },
  };
}

Map<String, dynamic> sessionTunnelMcpEntry({
  required String clientId,
  required String description,
  required String alias,
}) {
  return {
    'id': clientId,
    'description': description,
    'streamable_http': {
      'url': 'tunnel://session-mcp/$alias',
      'headers': <String, String>{},
    },
  };
}
