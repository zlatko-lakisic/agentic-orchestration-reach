/// Hybrid MCP bootstrap: AO sandbox deploy first, tunnel fallback.
library;

import 'dart:io';

import 'connection_config.dart';
import 'local_mcp_host.dart';
import 'mcp_bootstrap.dart';
import 'mcp_session_spec.dart';
import 'sandbox_deploy_client.dart';
import 'tool_packager.dart';

class CustomToolDeploySpec {
  CustomToolDeploySpec({
    required this.toolId,
    required this.description,
    this.manifest,
    this.manifestFile,
    this.wheelFile,
    this.projectDir,
    this.tunnelSpec,
    this.alias,
  });

  final String toolId;
  final String description;
  final Map<String, dynamic>? manifest;
  final String? manifestFile;
  final String? wheelFile;
  final String? projectDir;
  final McpSessionSpec? tunnelSpec;
  final String? alias;

  Future<CustomToolBundle> resolveBundle() => packageCustomTool(
        manifest: manifest,
        manifestFile: manifestFile != null ? File(manifestFile!) : null,
        wheelFile: wheelFile != null ? File(wheelFile!) : null,
        projectDir: projectDir != null ? Directory(projectDir!) : null,
      );
}

/// Try AO sandbox activation per tool; fall back to stdio tunnel on failure.
class HybridSessionMcpBootstrap implements SessionMcpBootstrap {
  HybridSessionMcpBootstrap({
    required List<CustomToolDeploySpec> tools,
    SessionMcpBootstrap inner = const EmptySessionMcpBootstrap(),
    ReachSandboxDeployClient? deployClient,
    ReachConnectionConfig? config,
  })  : _tools = List.unmodifiable(tools),
        _inner = inner,
        _deployClient = deployClient ?? ReachSandboxDeployClient(),
        _config = config;

  final List<CustomToolDeploySpec> _tools;
  final SessionMcpBootstrap _inner;
  final ReachSandboxDeployClient _deployClient;
  final ReachConnectionConfig? _config;
  bool aoCustomToolSandbox = false;

  @override
  Future<SessionMcpBootstrapResult> prepare(
    LocalMcpHost host, {
    required bool mcpTunnel,
    ReachConnectionConfig? config,
    bool customToolSandbox = false,
  }) async {
    final effective = config ?? _config;
    final aoSandbox = customToolSandbox || aoCustomToolSandbox;
    final innerResult = await _inner.prepare(
      host,
      mcpTunnel: mcpTunnel,
      config: effective,
      customToolSandbox: aoSandbox,
    );

    if (effective == null ||
        !effective.deployToAoSandbox ||
        !aoSandbox ||
        _tools.isEmpty) {
      return innerResult;
    }

    final toolIds = _tools.map((t) => t.toolId).toSet();
    final mcps = innerResult.mcps
        .where((m) => !toolIds.contains(m['id']?.toString() ?? ''))
        .toList();
    final warnings = List<String>.from(innerResult.warnings);
    final tunnelIds = List<String>.from(innerResult.activeTunnelBareIds);
    final sessionEnv = effective.sessionEnv ?? const <String, String>{};

    for (final spec in _tools) {
      try {
        final bundle = await spec.resolveBundle();
        final deployed = await _deployClient.uploadAndActivate(
          effective,
          bundle,
          env: sessionEnv,
        );
        if (deployed.ok) {
          // AO merges activated sandbox MCPs server-side; do not register
          // loopback sandbox URLs in session_overlay_register.
          continue;
        }
        throw StateError(deployed.error ?? deployed.fallbackReason ?? 'sandbox_unavailable');
      } catch (e) {
        final msg =
            'sandbox deploy failed for ${spec.toolId}: $e; using tunnel fallback';
        warnings.add(msg);
        final fallback = await _tunnelFallback(host, spec, mcpTunnel: mcpTunnel);
        if (fallback != null) {
          mcps.add(fallback.entry);
          if (fallback.bareId != null && !tunnelIds.contains(fallback.bareId!)) {
            tunnelIds.add(fallback.bareId!);
          }
        }
      }
    }

    return SessionMcpBootstrapResult(
      mcps: mcps,
      warnings: warnings,
      filesystemActive: innerResult.filesystemActive,
      emailGmailActive: innerResult.emailGmailActive,
      calendarGoogleActive: innerResult.calendarGoogleActive,
      activeTunnelBareIds: tunnelIds,
    );
  }

  Future<({Map<String, dynamic> entry, String? bareId})?> _tunnelFallback(
    LocalMcpHost host,
    CustomToolDeploySpec spec, {
    required bool mcpTunnel,
  }) async {
    if (!mcpTunnel) return null;
    var tunnel = spec.tunnelSpec;
    if (tunnel == null) {
      final bare = spec.toolId.split('.').last;
      final alias = spec.alias ?? bare;
      tunnel = McpSessionSpec(
        bareId: bare,
        alias: alias,
        transport: McpSessionTransport.stdioTunnel,
        description: spec.description,
        pythonModule: 'echo_tool.mcp',
      );
    }
    if (tunnel.transport != McpSessionTransport.stdioTunnel) return null;
    if (!host.isAliasRunning(tunnel.alias)) {
      if (tunnel.pythonModule != null) {
        await host.startPythonModule(
          alias: tunnel.alias,
          module: tunnel.pythonModule!,
        );
      } else if (tunnel.npxPackage != null) {
        await host.startNpxPackage(
          alias: tunnel.alias,
          package: tunnel.npxPackage!,
        );
      } else {
        return null;
      }
    }
    return (
      entry: sessionTunnelMcpEntry(
        clientId: spec.toolId,
        description: spec.description,
        alias: tunnel.alias,
      ),
      bareId: tunnel.bareId,
    );
  }
}

const mockClientProfiles = <String, List<({String toolId, String description})>>{
  'mock-comstar': [
    (toolId: 'client.mock_comstar.fake_lsp_bridge', description: 'Mock LSP bridge'),
    (
      toolId: 'client.mock_comstar.nonexistent_refactor',
      description: 'Mock refactor tool',
    ),
  ],
  'mock-continue': [
    (
      toolId: 'client.mock_continue.fake_workspace_index',
      description: 'Mock workspace index',
    ),
    (
      toolId: 'client.mock_continue.ghost_completion',
      description: 'Mock ghost completion',
    ),
  ],
  'mock-ha': [
    (
      toolId: 'client.mock_ha.fake_entity_registry',
      description: 'Mock HA entity registry',
    ),
    (
      toolId: 'client.mock_ha.synthetic_automation',
      description: 'Mock HA automation',
    ),
  ],
};

List<CustomToolDeploySpec> mockProfileTools(String appId) {
  final tools = mockClientProfiles[appId];
  if (tools == null) {
    throw ArgumentError.value(appId, 'appId', 'unknown mock profile');
  }
  return tools
      .map(
        (t) => CustomToolDeploySpec(
          toolId: t.toolId,
          description: t.description,
          alias: t.toolId.split('.').last,
        ),
      )
      .toList();
}
