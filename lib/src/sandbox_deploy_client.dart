/// HTTP client for AO custom-tool sandbox upload + activate (mTLS-aware).
library;

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import 'connection_config.dart';
import 'mtls.dart';
import 'tool_packager.dart';

class SandboxDeployResult {
  SandboxDeployResult({
    required this.ok,
    this.mcp,
    this.error,
    this.fallbackReason,
    this.toolId = '',
    this.toolVersion = '',
    this.raw = const {},
  });

  final bool ok;
  final Map<String, dynamic>? mcp;
  final String? error;
  final String? fallbackReason;
  final String toolId;
  final String toolVersion;
  final Map<String, dynamic> raw;

  Map<String, dynamic>? get mcpEntry => mcp;
}

/// Upload and activate wheel+manifest bundles against AO REST APIs.
class ReachSandboxDeployClient {
  ReachSandboxDeployClient({http.Client? httpClient}) : _httpClient = httpClient;

  final http.Client? _httpClient;

  http.Client _client(ReachConnectionConfig config) {
    if (_httpClient != null) return _httpClient;
    final mtls = config.mtls;
    if (mtls != null) {
      assertReachMtlsUsesTls(config.baseUrl);
      final material = loadReachMtlsMaterial(mtls);
      return IOClient(reachMtlsHttpClient(material));
    }
    return http.Client();
  }

  Future<Map<String, dynamic>> upload(
    ReachConnectionConfig config,
    CustomToolBundle bundle,
  ) async {
    final base = config.baseUrl.replaceAll(RegExp(r'/+$'), '');
    final uri = Uri.parse('$base/api/v1/custom-tools/upload').replace(
      queryParameters: {'appId': config.appId},
    );

    http.Client? owned;
    final client = _httpClient ?? (owned = _client(config));
    try {
      final res = await client.post(
        uri,
        headers: {
          ...config.headers,
          'Content-Type': 'application/zip',
        },
        body: bundle.zipBytes,
      );
      if (res.statusCode < 200 || res.statusCode >= 300) {
        throw StateError(
          'POST /api/v1/custom-tools/upload failed: HTTP ${res.statusCode} ${res.body}',
        );
      }
      final decoded = jsonDecode(res.body);
      if (decoded is! Map) throw StateError('upload: expected JSON object');
      return Map<String, dynamic>.from(decoded);
    } finally {
      owned?.close();
      if (_httpClient == null && owned == null) client.close();
    }
  }

  Future<SandboxDeployResult> activate(
    ReachConnectionConfig config, {
    required String toolId,
    required String toolVersion,
    Map<String, String>? env,
  }) async {
    final base = config.baseUrl.replaceAll(RegExp(r'/+$'), '');
    final uri = Uri.parse('$base/api/v1/custom-tools/activate');
    final payload = {
      'appId': config.appId,
      'toolId': toolId,
      'toolVersion': toolVersion,
      'env': env ?? const <String, String>{},
    };

    http.Client? owned;
    final client = _httpClient ?? (owned = _client(config));
    try {
      final res = await client.post(
        uri,
        headers: {
          ...config.headers,
          'Content-Type': 'application/json',
        },
        body: jsonEncode(payload),
      );
      if (res.statusCode < 200 || res.statusCode >= 300) {
        return SandboxDeployResult(
          ok: false,
          error: 'HTTP ${res.statusCode} ${res.body}',
          fallbackReason: 'ao_activate_failed',
          toolId: toolId,
          toolVersion: toolVersion,
        );
      }
      final decoded = jsonDecode(res.body);
      if (decoded is! Map) {
        return SandboxDeployResult(
          ok: false,
          error: 'activate: expected JSON object',
          fallbackReason: 'ao_activate_failed',
          toolId: toolId,
          toolVersion: toolVersion,
        );
      }
      final data = Map<String, dynamic>.from(decoded);
      Map<String, dynamic>? mcp;
      if (data['mcp'] is Map) {
        mcp = Map<String, dynamic>.from(data['mcp'] as Map);
      } else if (data['mcpEntry'] is Map) {
        mcp = Map<String, dynamic>.from(data['mcpEntry'] as Map);
      }
      return SandboxDeployResult(
        ok: data['ok'] == true || mcp != null,
        mcp: mcp,
        toolId: toolId,
        toolVersion: toolVersion,
        raw: data,
      );
    } finally {
      owned?.close();
      if (_httpClient == null && owned == null) client.close();
    }
  }

  Future<SandboxDeployResult> deployBundle(
    ReachConnectionConfig config,
    CustomToolBundle bundle, {
    Map<String, String>? env,
  }) async {
    try {
      await upload(config, bundle);
    } catch (e) {
      return SandboxDeployResult(
        ok: false,
        error: e.toString(),
        fallbackReason: 'ao_upload_failed',
        toolId: bundle.manifest.toolId,
        toolVersion: bundle.manifest.toolVersion,
      );
    }
    return activate(
      config,
      toolId: bundle.manifest.toolId,
      toolVersion: bundle.manifest.toolVersion,
      env: env,
    );
  }

  Future<SandboxDeployResult> uploadAndActivate(
    ReachConnectionConfig config,
    CustomToolBundle bundle, {
    Map<String, String>? env,
  }) =>
      deployBundle(config, bundle, env: env);
}
