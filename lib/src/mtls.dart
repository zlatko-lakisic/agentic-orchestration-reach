import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// PEM material (or on-disk directory) for Reach ↔ AO mutual TLS.
class ReachMtlsConfig {
  const ReachMtlsConfig({
    this.clientCertPem,
    this.clientKeyPem,
    this.caPem,
    this.materialDir,
  });

  /// Client certificate PEM (leaf).
  final String? clientCertPem;

  /// Client private key PEM.
  final String? clientKeyPem;

  /// AO CA PEM used to trust the server (and verify chain).
  final String? caPem;

  /// Directory containing `cert.pem`, `key.pem`, `ca.pem` (written by [ReachMtlsEnroller]).
  final String? materialDir;

  bool get hasInlineMaterial =>
      (clientCertPem?.trim().isNotEmpty ?? false) &&
      (clientKeyPem?.trim().isNotEmpty ?? false) &&
      (caPem?.trim().isNotEmpty ?? false);

  bool get hasMaterialDir =>
      materialDir != null && materialDir!.trim().isNotEmpty;

  bool get isConfigured => hasInlineMaterial || hasMaterialDir;

  ReachMtlsConfig copyWith({
    String? clientCertPem,
    String? clientKeyPem,
    String? caPem,
    String? materialDir,
  }) {
    return ReachMtlsConfig(
      clientCertPem: clientCertPem ?? this.clientCertPem,
      clientKeyPem: clientKeyPem ?? this.clientKeyPem,
      caPem: caPem ?? this.caPem,
      materialDir: materialDir ?? this.materialDir,
    );
  }
}

/// Loaded PEMs ready for [SecurityContext] / persistence.
class ReachMtlsMaterial {
  const ReachMtlsMaterial({
    required this.clientCertPem,
    required this.clientKeyPem,
    required this.caPem,
    this.dir,
    this.subject,
    this.expiresAt,
  });

  final String clientCertPem;
  final String clientKeyPem;
  final String caPem;
  final String? dir;
  final String? subject;
  final double? expiresAt;

  ReachMtlsConfig toConfig() => ReachMtlsConfig(
        clientCertPem: clientCertPem,
        clientKeyPem: clientKeyPem,
        caPem: caPem,
        materialDir: dir,
      );
}

/// Resolve PEMs from inline config and/or [ReachMtlsConfig.materialDir].
ReachMtlsMaterial loadReachMtlsMaterial(ReachMtlsConfig config) {
  if (config.hasInlineMaterial) {
    return ReachMtlsMaterial(
      clientCertPem: config.clientCertPem!.trim(),
      clientKeyPem: config.clientKeyPem!.trim(),
      caPem: config.caPem!.trim(),
      dir: config.materialDir?.trim(),
    );
  }
  final dir = config.materialDir?.trim();
  if (dir == null || dir.isEmpty) {
    throw StateError('ReachMtlsConfig requires PEMs or materialDir');
  }
  final certPath = p.join(dir, 'cert.pem');
  final keyPath = p.join(dir, 'key.pem');
  final caPath = p.join(dir, 'ca.pem');
  for (final path in [certPath, keyPath, caPath]) {
    if (!File(path).existsSync()) {
      throw StateError('mTLS material missing: $path');
    }
  }
  return ReachMtlsMaterial(
    clientCertPem: File(certPath).readAsStringSync(),
    clientKeyPem: File(keyPath).readAsStringSync(),
    caPem: File(caPath).readAsStringSync(),
    dir: dir,
  );
}

/// Persist enrollment output for later [ReachConnectionConfig.mtls] use.
Future<ReachMtlsMaterial> persistReachMtlsMaterial({
  required String dir,
  required String clientCertPem,
  required String clientKeyPem,
  required String caPem,
  String? subject,
  double? expiresAt,
}) async {
  final directory = Directory(dir);
  await directory.create(recursive: true);
  final certFile = File(p.join(dir, 'cert.pem'));
  final keyFile = File(p.join(dir, 'key.pem'));
  final caFile = File(p.join(dir, 'ca.pem'));
  await certFile.writeAsString(clientCertPem, flush: true);
  await keyFile.writeAsString(clientKeyPem, flush: true);
  await caFile.writeAsString(caPem, flush: true);
  try {
    await Process.run('chmod', ['600', keyFile.path]);
    await Process.run('chmod', ['644', certFile.path, caFile.path]);
  } catch (_) {}
  return ReachMtlsMaterial(
    clientCertPem: clientCertPem,
    clientKeyPem: clientKeyPem,
    caPem: caPem,
    dir: dir,
    subject: subject,
    expiresAt: expiresAt,
  );
}

/// Build a [SecurityContext] that presents the client cert and trusts [caPem].
SecurityContext reachMtlsSecurityContext(ReachMtlsMaterial material) {
  final ctx = SecurityContext(withTrustedRoots: false);
  final caBytes = utf8.encode(material.caPem);
  final certBytes = utf8.encode(material.clientCertPem);
  final keyBytes = utf8.encode(material.clientKeyPem);
  ctx.setTrustedCertificatesBytes(caBytes);
  ctx.useCertificateChainBytes(certBytes);
  ctx.usePrivateKeyBytes(keyBytes);
  return ctx;
}

/// HTTP client that uses mTLS material (speech, enroll with existing cert, etc.).
HttpClient reachMtlsHttpClient(ReachMtlsMaterial material) {
  return HttpClient(context: reachMtlsSecurityContext(material));
}

/// Ensure [baseUrl] is https when mTLS is configured.
void assertReachMtlsUsesTls(String baseUrl) {
  final uri = Uri.parse(baseUrl.replaceAll(RegExp(r'/+$'), ''));
  if (uri.scheme != 'https') {
    throw ArgumentError(
      'mTLS requires an https baseUrl (got ${uri.scheme}://…). '
      'Reach talks to the AO engine directly over TLS.',
    );
  }
}
