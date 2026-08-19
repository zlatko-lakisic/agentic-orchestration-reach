/// Shared wheel+manifest contract for AO custom-tool sandbox deployment (v1).
library;

import 'dart:convert';

const String customToolContractVersion = '1';
const supportedCustomToolRuntimes = {'python'};
const customToolFallbackPolicies = {'tunnel', 'fail'};

final RegExp customToolIdPattern = RegExp(
  r'^client\.[a-z][a-z0-9_]*\.[a-z][a-z0-9_]+$',
);
final RegExp customToolSemverPattern = RegExp(
  r'^\d+\.\d+\.\d+(-[a-zA-Z0-9.]+)?(\+[a-zA-Z0-9.]+)?$',
);

class CustomToolContractError implements Exception {
  CustomToolContractError(this.message);
  final String message;
  @override
  String toString() => 'CustomToolContractError: $message';
}

class CustomToolPermissions {
  CustomToolPermissions({
    this.filesystem = const [],
    this.network = false,
    this.env = const [],
  });

  factory CustomToolPermissions.fromJson(Map<String, dynamic>? json) {
    final raw = json ?? {};
    return CustomToolPermissions(
      filesystem: _stringList(raw['filesystem']),
      network: raw['network'] == true,
      env: _stringList(raw['env']),
    );
  }

  final List<String> filesystem;
  final bool network;
  final List<String> env;

  Map<String, dynamic> toJson() => {
        'filesystem': filesystem,
        'network': network,
        'env': env,
      };
}

class CustomToolHealthcheck {
  CustomToolHealthcheck({
    this.path = '/health',
    this.timeoutSeconds = 5,
  });

  factory CustomToolHealthcheck.fromJson(Map<String, dynamic>? json) {
    final raw = json ?? {};
    final timeout = raw['timeoutSeconds'];
    if (timeout is num && timeout <= 0) {
      throw CustomToolContractError(
        'healthcheck.timeoutSeconds must be a positive number',
      );
    }
    return CustomToolHealthcheck(
      path: (raw['path'] ?? '/health').toString().trim().isEmpty
          ? '/health'
          : (raw['path'] ?? '/health').toString(),
      timeoutSeconds: timeout is num ? timeout.toInt() : 5,
    );
  }

  final String path;
  final int timeoutSeconds;

  Map<String, dynamic> toJson() => {
        'path': path,
        'timeoutSeconds': timeoutSeconds,
      };
}

class CustomToolManifest {
  CustomToolManifest({
    required this.contractVersion,
    required this.toolId,
    required this.toolVersion,
    required this.runtime,
    required this.wheel,
    required this.entrypoints,
    this.requiredEnv = const [],
    CustomToolPermissions? permissions,
    CustomToolHealthcheck? healthcheck,
    this.fallbackPolicy = 'tunnel',
    Map<String, dynamic>? raw,
  })  : permissions = permissions ?? CustomToolPermissions(),
        healthcheck = healthcheck ?? CustomToolHealthcheck(),
        raw = Map<String, dynamic>.from(raw ?? {});

  factory CustomToolManifest.fromJson(Map<String, dynamic> json) {
    validateManifestMap(json);
    final entryRaw = json['entrypoints'];
    final entrypoints = <String, String>{};
    if (entryRaw is Map) {
      entryRaw.forEach((k, v) => entrypoints[k.toString()] = v.toString());
    }
    return CustomToolManifest(
      contractVersion: json['contractVersion'].toString(),
      toolId: json['toolId'].toString(),
      toolVersion: json['toolVersion'].toString(),
      runtime: json['runtime'].toString(),
      wheel: json['wheel'].toString(),
      entrypoints: entrypoints,
      requiredEnv: _stringList(json['requiredEnv']),
      permissions: CustomToolPermissions.fromJson(
        json['permissions'] is Map
            ? Map<String, dynamic>.from(json['permissions'] as Map)
            : null,
      ),
      healthcheck: CustomToolHealthcheck.fromJson(
        json['healthcheck'] is Map
            ? Map<String, dynamic>.from(json['healthcheck'] as Map)
            : null,
      ),
      fallbackPolicy: (json['fallbackPolicy'] ?? 'tunnel').toString(),
      raw: json,
    );
  }

  final String contractVersion;
  final String toolId;
  final String toolVersion;
  final String runtime;
  final String wheel;
  final Map<String, String> entrypoints;
  final List<String> requiredEnv;
  final CustomToolPermissions permissions;
  final CustomToolHealthcheck healthcheck;
  final String fallbackPolicy;
  final Map<String, dynamic> raw;

  Map<String, dynamic> toJson() => {
        'contractVersion': contractVersion,
        'toolId': toolId,
        'toolVersion': toolVersion,
        'runtime': runtime,
        'wheel': wheel,
        'entrypoints': entrypoints,
        'requiredEnv': requiredEnv,
        'permissions': permissions.toJson(),
        'healthcheck': healthcheck.toJson(),
        'fallbackPolicy': fallbackPolicy,
      };

  String toJsonString() => '${jsonEncode(toJson())}\n';
}

void validateManifestMap(dynamic data) {
  if (data is! Map) {
    throw CustomToolContractError('manifest must be a JSON object');
  }
  final json = Map<String, dynamic>.from(data);
  for (final key in [
    'contractVersion',
    'toolId',
    'toolVersion',
    'runtime',
    'wheel',
    'entrypoints',
  ]) {
    if (!json.containsKey(key) || json[key] == null || json[key].toString().trim().isEmpty) {
      throw CustomToolContractError('manifest missing required field: $key');
    }
  }
  final version = json['contractVersion'].toString().trim();
  if (version != customToolContractVersion) {
    throw CustomToolContractError(
      'unsupported contractVersion $version (expected $customToolContractVersion)',
    );
  }
  final toolId = json['toolId'].toString().trim();
  if (!customToolIdPattern.hasMatch(toolId)) {
    throw CustomToolContractError(
      'toolId must match client.<app>.<name>: $toolId',
    );
  }
  final toolVersion = json['toolVersion'].toString().trim();
  if (!customToolSemverPattern.hasMatch(toolVersion)) {
    throw CustomToolContractError('toolVersion must be semver: $toolVersion');
  }
  final runtime = json['runtime'].toString().trim().toLowerCase();
  if (!supportedCustomToolRuntimes.contains(runtime)) {
    throw CustomToolContractError('unsupported runtime $runtime');
  }
  final wheel = json['wheel'].toString().trim();
  if (!wheel.endsWith('.whl')) {
    throw CustomToolContractError('wheel must be a .whl filename');
  }
  final entryRaw = json['entrypoints'];
  if (entryRaw is! Map || entryRaw.isEmpty) {
    throw CustomToolContractError('entrypoints must be a non-empty object');
  }
  if (!entryRaw.containsKey('mcp') || '$entryRaw[mcp]'.trim().isEmpty) {
    throw CustomToolContractError('entrypoints.mcp is required');
  }
  final fallback = (json['fallbackPolicy'] ?? 'tunnel').toString().toLowerCase();
  if (!customToolFallbackPolicies.contains(fallback)) {
    throw CustomToolContractError(
      'fallbackPolicy must be one of ${customToolFallbackPolicies.join(', ')}',
    );
  }
  CustomToolPermissions.fromJson(
    json['permissions'] is Map
        ? Map<String, dynamic>.from(json['permissions'] as Map)
        : null,
  );
  CustomToolHealthcheck.fromJson(
    json['healthcheck'] is Map
        ? Map<String, dynamic>.from(json['healthcheck'] as Map)
        : null,
  );
}

String appIdFromToolId(String toolId) {
  final parts = toolId.split('.');
  if (parts.length < 3 || parts.first != 'client') {
    throw CustomToolContractError('invalid toolId: $toolId');
  }
  return parts[1].replaceAll('_', '-');
}

List<String> _stringList(dynamic raw) {
  if (raw is! List) return const [];
  return raw.map((e) => e.toString().trim()).where((s) => s.isNotEmpty).toList();
}
