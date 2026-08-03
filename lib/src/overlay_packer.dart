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

  List<String> get skillIds =>
      skills.map((s) => s['id']?.toString() ?? '').where((id) => id.isNotEmpty).toList();
}

/// Load overlay catalogs in the AO layout:
/// `agent_providers/`, optional `agent_skills/`, plus session MCP entries.
///
/// For remote session overlays, strips spawn-local ollama flags so AO (v1.27.1+)
/// resolves the host from its env and pulls missing models on register.
///
/// Agents may list bare skill ids under `skills:`; those are rewritten to
/// `client.*` and their markdown is injected into `backstory` (AO inject default)
/// so direct_agent turns still see them without AO workflow skill attachment.
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

    final skillByBare = await _loadSkills(overlayRoot);
    final skills = skillByBare.values.toList()
      ..sort((a, b) => (a['id'] as String).compareTo(b['id'] as String));

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
      _attachSkillsToAgent(out, skillByBare);
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

    return SessionOverlayPack(agents: agents, mcps: mcps, skills: skills);
  }

  /// Load `overlayRoot/agent_skills/*.yaml` (AO skill schema). Missing dir → {}.
  Future<Map<String, Map<String, dynamic>>> _loadSkills(String overlayRoot) async {
    final dir = Directory(p.join(overlayRoot, 'agent_skills'));
    if (!await dir.exists()) return {};

    final out = <String, Map<String, dynamic>>{};
    final files = await dir
        .list()
        .where((e) => e is File && (e.path.endsWith('.yaml') || e.path.endsWith('.yml')))
        .cast<File>()
        .toList();
    files.sort((a, b) => p.basename(a.path).compareTo(p.basename(b.path)));

    for (final file in files) {
      final decoded = loadYaml(await file.readAsString());
      if (decoded is! YamlMap) continue;
      final map = _yamlToMap(decoded);
      final bareId = (map['id'] ?? '').toString().trim();
      if (bareId.isEmpty) continue;

      final content = map['content'];
      if (content is Map) {
        final fileRel = content['file']?.toString().trim();
        if (fileRel != null && fileRel.isNotEmpty) {
          final bodyPath = p.join(p.dirname(file.path), fileRel);
          final bodyFile = File(bodyPath);
          if (await bodyFile.exists()) {
            final body = await bodyFile.readAsString();
            final contentOut = Map<String, dynamic>.from(content);
            contentOut.remove('file');
            contentOut['body'] = _stripYamlFrontmatter(body);
            map['content'] = contentOut;
          }
        }
      }

      map['id'] = toClientAgentId(bareId);
      out[bareAgentId(bareId)] = map;
    }
    return out;
  }

  void _attachSkillsToAgent(
    Map<String, dynamic> agent,
    Map<String, Map<String, dynamic>> skillByBare,
  ) {
    final raw = agent['skills'];
    if (raw is! List || raw.isEmpty) return;

    final clientIds = <String>[];
    final chunks = <String>[];
    for (final item in raw) {
      final bare = bareAgentId(item.toString());
      if (bare.isEmpty) continue;
      final skill = skillByBare[bare];
      if (skill == null) continue;
      clientIds.add(toClientAgentId(bare));
      final inject = skill['inject'];
      final heading = inject is Map
          ? (inject['heading']?.toString() ?? '## Skill: $bare')
          : '## Skill: $bare';
      final content = skill['content'];
      final body = content is Map ? content['body']?.toString() ?? '' : '';
      if (body.trim().isEmpty) continue;
      chunks.add('$heading\n\n${body.trim()}');
    }
    agent['skills'] = clientIds;
    if (chunks.isEmpty) return;

    final block = chunks.join('\n\n');
    final existing = agent['backstory']?.toString() ?? '';
    agent['backstory'] =
        existing.trim().isEmpty ? block : '${existing.trim()}\n\n$block';
  }
}

String _stripYamlFrontmatter(String raw) {
  final t = raw.trimLeft();
  if (!t.startsWith('---')) return raw;
  final end = t.indexOf('\n---', 3);
  if (end < 0) return raw;
  final after = t.substring(end + 4);
  return after.startsWith('\n') ? after.substring(1) : after;
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
