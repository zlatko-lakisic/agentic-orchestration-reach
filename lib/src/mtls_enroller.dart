import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:path/path.dart' as p;

import 'mtls.dart';

/// One-time enrollment: generate key+CSR, redeem AO token, persist material.
///
/// Talks to the AO engine directly (`POST /api/v1/mtls/enroll`). Requires
/// `openssl` on PATH for key/CSR generation.
class ReachMtlsEnroller {
  ReachMtlsEnroller({http.Client? httpClient}) : _httpClient = httpClient;

  final http.Client? _httpClient;

  /// Enroll with a one-time token from `python -m orchestration.serve.mtls mint-token`.
  ///
  /// Bootstrap trust: pass [caPem] if known, or set [trustEnrollmentCa] to fetch
  /// and pin `GET /api/v1/mtls/ca` once (TOFU). Never both silent.
  Future<ReachMtlsMaterial> enroll({
    required String baseUrl,
    required String enrollToken,
    String? materialDir,
    String? commonName,
    String? caPem,
    bool trustEnrollmentCa = false,
    Directory? workDir,
  }) async {
    assertReachMtlsUsesTls(baseUrl);
    final token = enrollToken.trim();
    if (token.isEmpty) {
      throw ArgumentError('enrollToken is required');
    }
    final cn = (commonName?.trim().isNotEmpty ?? false)
        ? commonName!.trim()
        : 'reach-${DateTime.now().millisecondsSinceEpoch}';

    final base = baseUrl.replaceAll(RegExp(r'/+$'), '');
    var pinnedCa = caPem?.trim();
    final client = await _bootstrapClient(
      baseUrl: base,
      caPem: pinnedCa,
      trustEnrollmentCa: trustEnrollmentCa,
    );
    try {
      if (pinnedCa == null || pinnedCa.isEmpty) {
        if (!trustEnrollmentCa) {
          throw StateError(
            'Pass caPem or trustEnrollmentCa: true to trust the AO CA on first enroll',
          );
        }
        pinnedCa = await _fetchCaPem(client, base);
      }

      final dir = workDir ??
          Directory.systemTemp.createTempSync('ao-reach-mtls-');
      try {
        final keyPath = p.join(dir.path, 'key.pem');
        final csrPath = p.join(dir.path, 'csr.pem');
        await _opensslGenerateKeyAndCsr(cn: cn, keyPath: keyPath, csrPath: csrPath);
        final csrPem = await File(csrPath).readAsString();
        final keyPem = await File(keyPath).readAsString();

        final enrolled = await _postEnroll(
          client: client,
          baseUrl: base,
          token: token,
          csrPem: csrPem,
          clientName: cn,
        );
        final outDir = materialDir?.trim().isNotEmpty == true
            ? materialDir!.trim()
            : p.join(Directory.current.path, '.ao-mtls');
        return persistReachMtlsMaterial(
          dir: outDir,
          clientCertPem: enrolled.certificatePem,
          clientKeyPem: keyPem,
          caPem: enrolled.caPem.isNotEmpty ? enrolled.caPem : pinnedCa,
          subject: enrolled.subject,
          expiresAt: enrolled.expiresAt,
        );
      } finally {
        if (workDir == null) {
          try {
            dir.deleteSync(recursive: true);
          } catch (_) {}
        }
      }
    } finally {
      if (_httpClient == null) {
        client.close();
      }
    }
  }

  Future<http.Client> _bootstrapClient({
    required String baseUrl,
    required String? caPem,
    required bool trustEnrollmentCa,
  }) async {
    if (_httpClient != null) return _httpClient;
    if (caPem != null && caPem.trim().isNotEmpty) {
      final ctx = SecurityContext(withTrustedRoots: false);
      ctx.setTrustedCertificatesBytes(utf8.encode(caPem));
      return IOClient(HttpClient(context: ctx));
    }
    if (trustEnrollmentCa) {
      // Temporary TOFU: accept server cert to fetch CA, then pin.
      final httpClient = HttpClient();
      httpClient.badCertificateCallback = (cert, host, port) => true;
      return IOClient(httpClient);
    }
    return http.Client();
  }

  Future<String> _fetchCaPem(http.Client client, String baseUrl) async {
    final res = await client.get(Uri.parse('$baseUrl/api/v1/mtls/ca'));
    if (res.statusCode != 200) {
      throw StateError('GET /api/v1/mtls/ca failed: HTTP ${res.statusCode} ${res.body}');
    }
    final body = jsonDecode(res.body);
    if (body is! Map || body['caPem'] is! String) {
      throw StateError('GET /api/v1/mtls/ca: missing caPem');
    }
    final pem = (body['caPem'] as String).trim();
    if (pem.isEmpty) throw StateError('GET /api/v1/mtls/ca: empty caPem');
    return pem;
  }

  Future<_EnrollResult> _postEnroll({
    required http.Client client,
    required String baseUrl,
    required String token,
    required String csrPem,
    required String clientName,
  }) async {
    final res = await client.post(
      Uri.parse('$baseUrl/api/v1/mtls/enroll'),
      headers: {'Content-Type': 'application/json', 'Accept': 'application/json'},
      body: jsonEncode({
        'csrPem': csrPem,
        'token': token,
        'clientName': clientName,
      }),
    );
    if (res.statusCode != 200) {
      throw StateError(
        'POST /api/v1/mtls/enroll failed: HTTP ${res.statusCode} ${res.body}',
      );
    }
    final body = jsonDecode(res.body);
    if (body is! Map || body['ok'] != true) {
      throw StateError('enroll failed: ${res.body}');
    }
    return _EnrollResult(
      certificatePem: body['certificatePem'] as String,
      caPem: (body['caPem'] as String?) ?? '',
      subject: body['subject'] as String?,
      expiresAt: (body['expiresAt'] is num)
          ? (body['expiresAt'] as num).toDouble()
          : null,
    );
  }

  Future<void> _opensslGenerateKeyAndCsr({
    required String cn,
    required String keyPath,
    required String csrPath,
  }) async {
    final key = await Process.run('openssl', [
      'genrsa',
      '-out',
      keyPath,
      '2048',
    ]);
    if (key.exitCode != 0) {
      throw StateError(
        'openssl genrsa failed (is openssl on PATH?): ${key.stderr}',
      );
    }
    final csr = await Process.run('openssl', [
      'req',
      '-new',
      '-key',
      keyPath,
      '-out',
      csrPath,
      '-subj',
      '/CN=$cn',
    ]);
    if (csr.exitCode != 0) {
      throw StateError('openssl req failed: ${csr.stderr}');
    }
  }
}

class _EnrollResult {
  _EnrollResult({
    required this.certificatePem,
    required this.caPem,
    this.subject,
    this.expiresAt,
  });

  final String certificatePem;
  final String caPem;
  final String? subject;
  final double? expiresAt;
}
