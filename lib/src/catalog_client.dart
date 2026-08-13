/// Fetch AO stock catalog (agents / MCPs / skills / harnesses + requiredSecrets).
///
/// Calls engine `GET /api/v1/catalog` (mTLS when [ReachConnectionConfig.mtls] is set).
library;

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import 'connection_config.dart';
import 'mtls.dart';

/// One secret / env field a client UI should collect when enabling a catalog entry.
class ReachCatalogSecretField {
  ReachCatalogSecretField({
    required this.name,
    required this.label,
    required this.secret,
    required this.required,
    this.anyOfGroup,
    this.sessionEnvAllowed = true,
  });

  factory ReachCatalogSecretField.fromJson(Map<String, dynamic> json) {
    return ReachCatalogSecretField(
      name: (json['name'] ?? '').toString(),
      label: (json['label'] ?? json['name'] ?? '').toString(),
      secret: json['secret'] != false,
      required: json['required'] == true,
      anyOfGroup: json['anyOfGroup']?.toString(),
      sessionEnvAllowed: json['sessionEnvAllowed'] != false,
    );
  }

  final String name;
  final String label;
  final bool secret;
  final bool required;
  final String? anyOfGroup;
  final bool sessionEnvAllowed;
}

/// One catalog entry (agent, MCP, skill, or harness).
class ReachCatalogEntry {
  ReachCatalogEntry({
    required this.id,
    required this.kind,
    this.type,
    this.role,
    this.goal,
    this.model,
    this.description,
    this.plannerHint,
    this.harnessProfile,
    this.transport,
    this.enableField,
    this.requiredSecrets = const [],
    this.raw = const {},
  });

  factory ReachCatalogEntry.fromJson(Map<String, dynamic> json, {String? kind}) {
    final secretsRaw = json['requiredSecrets'];
    final secrets = <ReachCatalogSecretField>[];
    if (secretsRaw is List) {
      for (final item in secretsRaw) {
        if (item is Map<String, dynamic>) {
          secrets.add(ReachCatalogSecretField.fromJson(item));
        } else if (item is Map) {
          secrets.add(
            ReachCatalogSecretField.fromJson(Map<String, dynamic>.from(item)),
          );
        }
      }
    }
    return ReachCatalogEntry(
      id: (json['id'] ?? '').toString(),
      kind: (kind ?? json['kind'] ?? '').toString(),
      type: json['type']?.toString(),
      role: json['role']?.toString(),
      goal: json['goal']?.toString(),
      model: json['model']?.toString(),
      description: json['description']?.toString(),
      plannerHint: json['plannerHint']?.toString(),
      harnessProfile: json['harnessProfile']?.toString(),
      transport: json['transport']?.toString(),
      enableField: json['enableField']?.toString(),
      requiredSecrets: List.unmodifiable(secrets),
      raw: Map<String, dynamic>.from(json),
    );
  }

  final String id;
  final String kind;
  final String? type;
  final String? role;
  final String? goal;
  final String? model;
  final String? description;
  final String? plannerHint;
  final String? harnessProfile;
  final String? transport;

  /// Overlay field to enable this entry (`allowedAgentProviderIds`, …).
  /// Null for harness profiles (selected via agent `harnessProfile`).
  final String? enableField;
  final List<ReachCatalogSecretField> requiredSecrets;
  final Map<String, dynamic> raw;
}

/// Parsed `GET /api/v1/catalog` response.
class ReachCatalog {
  ReachCatalog({
    required this.agents,
    required this.mcps,
    required this.skills,
    required this.harnesses,
    required this.sessionEnvAllowedKeys,
    required this.enableFields,
    this.generatedAt,
    this.raw = const {},
  });

  factory ReachCatalog.fromJson(Map<String, dynamic> json) {
    List<ReachCatalogEntry> parseList(String key, String kind) {
      final raw = json[key];
      if (raw is! List) return const [];
      final out = <ReachCatalogEntry>[];
      for (final item in raw) {
        if (item is Map<String, dynamic>) {
          out.add(ReachCatalogEntry.fromJson(item, kind: kind));
        } else if (item is Map) {
          out.add(
            ReachCatalogEntry.fromJson(
              Map<String, dynamic>.from(item),
              kind: kind,
            ),
          );
        }
      }
      return List.unmodifiable(out);
    }

    final keysRaw = json['sessionEnvAllowedKeys'];
    final keys = <String>[];
    if (keysRaw is List) {
      for (final k in keysRaw) {
        final s = k.toString().trim();
        if (s.isNotEmpty) keys.add(s);
      }
    }
    final enableRaw = json['enableFields'];
    final enable = <String, String?>{};
    if (enableRaw is Map) {
      enableRaw.forEach((k, v) {
        enable[k.toString()] = v?.toString();
      });
    }

    return ReachCatalog(
      agents: parseList('agents', 'agent'),
      mcps: parseList('mcps', 'mcp'),
      skills: parseList('skills', 'skill'),
      harnesses: parseList('harnesses', 'harness'),
      sessionEnvAllowedKeys: List.unmodifiable(keys),
      enableFields: Map.unmodifiable(enable),
      generatedAt: json['generatedAt']?.toString(),
      raw: Map<String, dynamic>.from(json),
    );
  }

  final List<ReachCatalogEntry> agents;
  final List<ReachCatalogEntry> mcps;
  final List<ReachCatalogEntry> skills;
  final List<ReachCatalogEntry> harnesses;
  final List<String> sessionEnvAllowedKeys;
  final Map<String, String?> enableFields;
  final String? generatedAt;
  final Map<String, dynamic> raw;

  /// All entries flattened (agents → mcps → skills → harnesses).
  List<ReachCatalogEntry> get all => [
        ...agents,
        ...mcps,
        ...skills,
        ...harnesses,
      ];
}

/// HTTP client for [ReachCatalog].
class ReachCatalogClient {
  ReachCatalogClient({http.Client? httpClient}) : _httpClient = httpClient;

  final http.Client? _httpClient;

  /// Fetch stock catalog. Pass [config] for base URL, headers, and optional mTLS.
  ///
  /// [kinds] may be a subset: `agents`, `mcps`, `skills`, `harnesses`.
  Future<ReachCatalog> fetch(
    ReachConnectionConfig config, {
    List<String>? kinds,
  }) async {
    final base = config.baseUrl.replaceAll(RegExp(r'/+$'), '');
    final query = <String, String>{};
    if (kinds != null && kinds.isNotEmpty) {
      query['kinds'] = kinds.join(',');
    }
    final uri = Uri.parse('$base/api/v1/catalog').replace(queryParameters: query);

    http.Client? owned;
    final client = _httpClient ??
        () {
          final mtls = config.mtls;
          if (mtls != null) {
            assertReachMtlsUsesTls(config.baseUrl);
            final material = loadReachMtlsMaterial(mtls);
            owned = IOClient(reachMtlsHttpClient(material));
            return owned!;
          }
          return http.Client();
        }();

    try {
      final res = await client.get(uri, headers: {
        ...config.headers,
        'Accept': 'application/json',
      });
      if (res.statusCode < 200 || res.statusCode >= 300) {
        throw StateError(
          'GET /api/v1/catalog failed: HTTP ${res.statusCode} ${res.body}',
        );
      }
      final decoded = jsonDecode(res.body);
      if (decoded is! Map) {
        throw StateError('GET /api/v1/catalog: expected JSON object');
      }
      return ReachCatalog.fromJson(Map<String, dynamic>.from(decoded));
    } finally {
      if (owned != null) {
        owned!.close();
      } else if (_httpClient == null) {
        client.close();
      }
    }
  }
}
