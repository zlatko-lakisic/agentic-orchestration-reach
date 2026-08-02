import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import 'ids.dart';
import 'mcp_session_spec.dart';

/// Packed payload for AO `session_overlay_register` (v1.27+).
class SessionOverlayPack {
  const SessionOverlayPack({
    required this.agents,
    required this.mcps,
    this.skills = const [],
  });

  final List<Map<String, dynamic>> agents;
  final List<Map<String, dynamic>> mcps;
  final List<Map<String, dynamic>> skills;

  List<String> get agentIds =>
      agents.map((a) => a['id']?.toString() ?? '').where((id) => id.isNotEmpty).toList();

  List<String> get mcpIds =>
      mcps.map((m) => m['id']?.toString() ?? '').where((id) => id.isNotEmpty).toList();
}

/// Load `overlayRoot/agent_providers/*.yaml` and rewrite ids to `client.*`.
///
/// For remote session overlays, strips spawn-local ollama flags so AO (v1.27.1+)
/// resolves the host from its env and pulls missing models on register.
class OverlayPacker {
  Future<SessionOverlayPack> pack({
    required String overlayRoot,
    bool includeFilesystemMcp = false,
    bool includeEmailGmailMcp = false,
    bool includeCalendarGoogleMcp = false,
    /// Specs for stdio tunnel MCPs already started (or to declare).
    List<McpSessionSpec> tunnelSpecs = const [],
    /// Pre-built HTTP (or other) session MCP entries.
    List<Map<String, dynamic>> httpMcps = const [],
    /// Extra pre-built MCP entries (merged after conveniences).
    List<Map<String, dynamic>> extraMcps = const [],
  }) async {
    final agentsDir = Directory(p.join(overlayRoot, 'agent_providers'));
    if (!await agentsDir.exists()) {
      throw StateError('Overlay agent_providers missing: ${agentsDir.path}');
    }

    final agents = <Map<String, dynamic>>[];
    final files = await agentsDir
        .list()
        .where((e) => e is File && e.path.endsWith('.yaml'))
        .cast<File>()
        .toList();
    files.sort((a, b) => p.basename(a.path).compareTo(p.basename(b.path)));

    for (final file in files) {
      final raw = await file.readAsString();
      final decoded = loadYaml(raw);
      if (decoded is! YamlMap) continue;
      final map = _yamlToMap(decoded);
      final bareId = (map['id'] ?? '').toString().trim();
      if (bareId.isEmpty) continue;
      final out = <String, dynamic>{};
      map.forEach((key, value) {
        out[key] = value;
      });
      out['id'] = toClientAgentId(bareId);
      if ((out['type']?.toString() ?? '').toLowerCase() == 'ollama') {
        out.remove('ollama_host');
        out['selfcontained'] = false;
      }
      agents.add(out);
    }

    if (agents.isEmpty) {
      throw StateError('No agent YAML found under ${agentsDir.path}');
    }

    final mcps = <Map<String, dynamic>>[];
    final seen = <String>{};

    void addMcp(Map<String, dynamic> entry) {
      final id = entry['id']?.toString() ?? '';
      if (id.isEmpty || !seen.add(id)) return;
      mcps.add(entry);
    }

    if (includeFilesystemMcp) {
      addMcp(sessionTunnelMcpEntry(
        clientId: clientFilesystemMcpId,
        description: 'User documents (session tunnel)',
        alias: filesystemTunnelAlias,
      ));
    }
    if (includeEmailGmailMcp) {
      addMcp(sessionTunnelMcpEntry(
        clientId: clientEmailGmailMcpId,
        description: 'Gmail (session tunnel)',
        alias: emailGmailTunnelAlias,
      ));
    }
    if (includeCalendarGoogleMcp) {
      addMcp(sessionTunnelMcpEntry(
        clientId: clientCalendarGoogleMcpId,
        description: 'Google Calendar (session tunnel)',
        alias: calendarGoogleTunnelAlias,
      ));
    }

    for (final spec in tunnelSpecs) {
      if (spec.transport != McpSessionTransport.stdioTunnel) continue;
      addMcp(sessionTunnelMcpEntry(
        clientId: spec.clientId,
        description: spec.description,
        alias: spec.alias,
      ));
    }

    for (final entry in httpMcps) {
      addMcp(entry);
    }
    for (final entry in extraMcps) {
      addMcp(entry);
    }

    return SessionOverlayPack(agents: agents, mcps: mcps, skills: const []);
  }
}

dynamic _yamlToDart(dynamic value) {
  if (value is YamlMap) return _yamlToMap(value);
  if (value is YamlList) return value.map(_yamlToDart).toList();
  return value;
}

Map<String, dynamic> _yamlToMap(YamlMap map) {
  final out = <String, dynamic>{};
  map.nodes.forEach((key, node) {
    final k = key is YamlScalar ? key.value?.toString() ?? '' : key.toString();
    if (k.isEmpty) return;
    out[k] = _yamlToDart(node.value);
  });
  return out;
}
