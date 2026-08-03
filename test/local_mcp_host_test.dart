import 'dart:convert';
import 'dart:io';

import 'package:ao_reach/ao_reach.dart';
import 'package:test/test.dart';

void main() {
  test('forward proxies to attached loopback alias', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() async => server.close(force: true));

    server.listen((req) async {
      final body = await utf8.decoder.bind(req).join();
      req.response.statusCode = 200;
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode({
        'echo': body,
        'path': req.uri.path,
        'method': req.method,
      }));
      await req.response.close();
    });

    final host = LocalMcpHost();
    host.attachLoopbackAlias('filesystem', server.port);
    expect(host.isAliasRunning('filesystem'), isTrue);
    expect(host.activeAliases, ['filesystem']);

    final result = await host.forward(
      alias: 'filesystem',
      method: 'POST',
      path: '/mcp',
      headers: {'content-type': 'application/json', 'host': 'evil'},
      body: utf8.encode('{"jsonrpc":"2.0","method":"ping"}'),
    );
    expect(result.status, 200);
    final decoded = jsonDecode(utf8.decode(result.body)) as Map;
    expect(decoded['path'], '/mcp');
    expect(decoded['method'], 'POST');
    expect(decoded['echo'], contains('ping'));

    await host.stop();
    expect(host.isRunning, isFalse);
  });

  test('forward unknown alias throws', () async {
    final host = LocalMcpHost();
    await expectLater(
      host.forward(
        alias: 'missing',
        method: 'GET',
        path: '/',
        headers: const {},
        body: const [],
      ),
      throwsA(isA<StateError>()),
    );
  });

  test('startFilesystem rejects empty allowlist', () async {
    final host = LocalMcpHost();
    await expectLater(host.startFilesystem(const []), throwsA(isA<StateError>()));
  });

  test('packageNameFromSpec strips versions', () {
    expect(LocalMcpHost.packageNameFromSpec('mcp-server-google-workspace@0.2.6'),
        'mcp-server-google-workspace');
    expect(LocalMcpHost.packageNameFromSpec('@scope/pkg@1.0.0'), '@scope/pkg');
    expect(LocalMcpHost.packageNameFromSpec('plain'), 'plain');
  });
}
