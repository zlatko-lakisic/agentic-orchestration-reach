import 'dart:io';

import 'package:ao_reach/ao_reach.dart';
import 'package:test/test.dart';

void main() {
  test('assertReachMtlsUsesTls rejects http', () {
    expect(
      () => assertReachMtlsUsesTls('http://ao:8765'),
      throwsA(isA<ArgumentError>()),
    );
    expect(() => assertReachMtlsUsesTls('https://ao:8765'), returnsNormally);
  });

  test('load and persist material dir', () async {
    final dir = Directory.systemTemp.createTempSync('reach-mtls-test-');
    addTearDown(() {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    });

    final material = await persistReachMtlsMaterial(
      dir: dir.path,
      clientCertPem: '-----BEGIN CERTIFICATE-----\nA\n-----END CERTIFICATE-----\n',
      clientKeyPem: '-----BEGIN RSA PRIVATE KEY-----\nB\n-----END RSA PRIVATE KEY-----\n',
      caPem: '-----BEGIN CERTIFICATE-----\nC\n-----END CERTIFICATE-----\n',
      subject: 'alice',
    );
    expect(material.dir, dir.path);
    expect(File('${dir.path}/cert.pem').existsSync(), isTrue);
    expect(File('${dir.path}/key.pem').existsSync(), isTrue);
    expect(File('${dir.path}/ca.pem').existsSync(), isTrue);

    final loaded = loadReachMtlsMaterial(ReachMtlsConfig(materialDir: dir.path));
    expect(loaded.clientCertPem, contains('BEGIN CERTIFICATE'));
    expect(loaded.caPem, contains('C'));
    // SecurityContext needs real PEMs; persistence/load is enough here.
  });

  test('ReachConnectionConfig carries mtls', () {
    final cfg = ReachConnectionConfig(
      baseUrl: 'https://ao:8765',
      headers: const {},
      mtls: const ReachMtlsConfig(materialDir: '/tmp/x'),
    );
    expect(cfg.mtls?.materialDir, '/tmp/x');
    expect(cfg.copyWith().mtls?.materialDir, '/tmp/x');
  });
}
