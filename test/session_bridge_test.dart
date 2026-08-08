import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ao_reach/ao_reach.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:web_socket_channel/io.dart';

String get _fixtureRoot => p.join(Directory.current.path, 'test', 'fixtures');

/// Loopback AO daemon stub for protocol regression tests.
class FakeAoWsServer {
  HttpServer? _server;
  WebSocket? _socket;
  final List<Map<String, dynamic>> clientMessages = [];
  final _msgController = StreamController<Map<String, dynamic>>.broadcast();

  late final int port;
  Uri get wsUri => Uri.parse('ws://127.0.0.1:$port/ws');
  String get httpBase => 'http://127.0.0.1:$port';

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    port = _server!.port;
    _server!.listen((req) async {
      if (req.uri.path != '/ws') {
        req.response.statusCode = 404;
        await req.response.close();
        return;
      }
      final ws = await WebSocketTransformer.upgrade(req);
      _socket = ws;
      ws.listen((raw) {
        final decoded = jsonDecode(raw as String) as Map<String, dynamic>;
        clientMessages.add(decoded);
        _msgController.add(decoded);
      });
    });
  }

  Future<void> dispose() async {
    await _socket?.close();
    await _server?.close(force: true);
    await _msgController.close();
  }

  void push(Map<String, dynamic> msg) {
    _socket?.add(jsonEncode(msg));
  }

  Future<void> waitUntilConnected({Duration timeout = const Duration(seconds: 2)}) async {
    final deadline = DateTime.now().add(timeout);
    while (_socket == null) {
      if (DateTime.now().isAfter(deadline)) {
        throw TimeoutException('WS client never connected');
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  Future<Map<String, dynamic>> waitForType(
    String type, {
    Duration timeout = const Duration(seconds: 3),
  }) async {
    for (final m in clientMessages) {
      if (m['type'] == type) return m;
    }
    return _msgController.stream
        .firstWhere((m) => m['type'] == type)
        .timeout(timeout);
  }
}

class _StaticBootstrap implements SessionMcpBootstrap {
  _StaticBootstrap(this.result);
  final SessionMcpBootstrapResult result;

  @override
  Future<SessionMcpBootstrapResult> prepare(
    LocalMcpHost host, {
    required bool mcpTunnel,
  }) async =>
      result;
}

void main() {
  late FakeAoWsServer server;
  late SessionBridge bridge;
  late Directory tempDir;

  setUp(() async {
    server = FakeAoWsServer();
    await server.start();
    tempDir = await Directory.systemTemp.createTemp('ao_reach_overlay_');
    final agents = Directory(p.join(tempDir.path, 'agent_providers'));
    await agents.create(recursive: true);
    for (final name in ['demo_agent.yaml', 'demo_agent_b.yaml']) {
      await File(p.join(_fixtureRoot, 'agent_providers', name))
          .copy(p.join(agents.path, name));
    }

    bridge = SessionBridge(
      wsConnect: (
        uri, {
        protocols,
        headers,
        pingInterval,
        connectTimeout,
      }) {
        return IOWebSocketChannel.connect(
          server.wsUri,
          headers: headers,
          pingInterval: pingInterval,
          connectTimeout: connectTimeout,
        );
      },
    );
  });

  tearDown(() async {
    await bridge.dispose();
    await server.dispose();
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  ReachConnectionConfig config({
    bool enabled = true,
    int maxReconnect = 0,
    String? speechSttBaseUrlOverride,
    String? speechTtsBaseUrlOverride,
  }) =>
      ReachConnectionConfig(
        baseUrl: server.httpBase,
        headers: const {
          'x-agentic-user-name': 'tester',
          'x-agentic-session-id': 's-test',
          'Accept': 'application/json',
        },
        appId: 'testapp',
        enabled: enabled,
        ttlSeconds: 120,
        questionIdPrefix: 'test',
        maxReconnectAttempts: maxReconnect,
        speechSttBaseUrlOverride: speechSttBaseUrlOverride,
        speechTtsBaseUrlOverride: speechTtsBaseUrlOverride,
      );

  Future<void> completeHandshake({
    bool overlay = true,
    bool tunnel = true,
    List<String>? mcpIds,
    SessionMcpBootstrap? bootstrap,
    Map<String, dynamic>? speech,
    ReachConnectionConfig? connectionConfig,
  }) async {
    final startFuture = bridge.start(
      config: connectionConfig ?? config(),
      overlayRoot: tempDir.path,
      mcpBootstrap: bootstrap ?? const EmptySessionMcpBootstrap(),
    );
    await server.waitUntilConnected();
    server.push({
      'type': 'hello',
      'sessionOverlay': overlay,
      'mcpTunnel': tunnel,
      if (speech != null) 'speech': speech,
    });
    final reg = await server.waitForType('session_overlay_register');
    expect(reg['appId'], 'testapp');
    expect(reg['ttlSeconds'], 120);
    expect(reg['agents'], isA<List>());
    server.push({
      'type': 'session_overlay_ack',
      'agentIds': (reg['agents'] as List).map((a) => (a as Map)['id']).toList(),
      'mcpIds': mcpIds ??
          (reg['mcps'] as List).map((m) => (m as Map)['id']).toList(),
      'expiresAt': 9999999999.0,
    });
    await startFuture;
  }

  test('disabled config stays idle', () async {
    await bridge.start(
      config: config(enabled: false),
      overlayRoot: tempDir.path,
    );
    expect(bridge.state, SessionBridgeState.idle);
    expect(server.clientMessages, isEmpty);
  });

  test('hello without sessionOverlay fails', () async {
    final fut = bridge.start(config: config(), overlayRoot: tempDir.path);
    await server.waitUntilConnected();
    server.push({'type': 'hello', 'sessionOverlay': false, 'mcpTunnel': true});
    await expectLater(fut, throwsA(isA<StateError>()));
    expect(bridge.state, SessionBridgeState.failed);
  });

  test('register → ack → active; packs client.* agents', () async {
    await completeHandshake();
    expect(bridge.state, SessionBridgeState.active);
    expect(bridge.sessionOverlay, isTrue);
    expect(bridge.speechClient, isNull);
    expect(bridge.registeredAgentIds, contains('client.demo_agent'));
    final reg = server.clientMessages
        .firstWhere((m) => m['type'] == 'session_overlay_register');
    final agents = (reg['agents'] as List).cast<Map>();
    final demo = agents.firstWhere((a) => a['id'] == 'client.demo_agent');
    expect(demo.containsKey('ollama_host'), isFalse);
    expect(demo['selfcontained'], isFalse);
  });

  test('hello speech advertises SpeechClient', () async {
    await completeHandshake(speech: {
      'enabled': true,
      'sttBaseUrl': 'http://10.0.0.5:8090',
      'ttsBaseUrl': 'http://10.0.0.5:8091',
      'auth': 'bearer',
    });
    expect(bridge.speech, isNotNull);
    expect(bridge.speechClient, isNotNull);
    expect(bridge.speech!.sttBaseUrl, 'http://10.0.0.5:8090');
    expect(bridge.speech!.authBearer, isTrue);
  });

  test('speech URL overrides replace advertised bases', () async {
    await completeHandshake(
      connectionConfig: config(
        speechSttBaseUrlOverride: 'http://10.0.0.5:8093/',
        speechTtsBaseUrlOverride: 'http://10.0.0.5:8092',
      ),
      speech: {
        'enabled': true,
        'sttBaseUrl': 'http://10.0.0.5:8090',
        'ttsBaseUrl': 'http://10.0.0.5:8091',
      },
    );
    expect(bridge.speech!.sttBaseUrl, 'http://10.0.0.5:8093');
    expect(bridge.speech!.ttsBaseUrl, 'http://10.0.0.5:8092');
    expect(bridge.speechClient, isNotNull);
  });

  test('progress chunks update registerProgress before ack', () async {
    final fut = bridge.start(config: config(), overlayRoot: tempDir.path);
    await server.waitUntilConnected();
    server.push({'type': 'hello', 'sessionOverlay': true, 'mcpTunnel': true});
    await server.waitForType('session_overlay_register');
    server.push({
      'type': 'chunk',
      'stream': 'stderr',
      'text': '(engine) pulling model',
    });
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(bridge.registerProgress, 'pulling model');
    server.push({
      'type': 'session_overlay_ack',
      'agentIds': ['client.demo_agent'],
      'mcpIds': <String>[],
    });
    await fut;
    expect(bridge.registerProgress, isNull);
  });

  test('ack mcpIds empty clears local filesystem flag', () async {
    await completeHandshake(
      mcpIds: const [],
      bootstrap: _StaticBootstrap(
        SessionMcpBootstrapResult(
          filesystemActive: true,
          mcps: [
            sessionTunnelMcpEntry(
              clientId: clientFilesystemMcpId,
              description: 'docs',
              alias: filesystemTunnelAlias,
            ),
          ],
        ),
      ),
    );
    expect(bridge.filesystemMcpActive, isFalse);
    expect(bridge.registeredMcpIds, isEmpty);
  });

  test('tunnel MCP without mcpTunnel capability fails', () async {
    final fut = bridge.start(
      config: config(),
      overlayRoot: tempDir.path,
      mcpBootstrap: _StaticBootstrap(
        SessionMcpBootstrapResult(
          filesystemActive: true,
          mcps: [
            sessionTunnelMcpEntry(
              clientId: clientFilesystemMcpId,
              description: 'docs',
              alias: filesystemTunnelAlias,
            ),
          ],
        ),
      ),
    );
    await server.waitUntilConnected();
    server.push({'type': 'hello', 'sessionOverlay': true, 'mcpTunnel': false});
    await expectLater(fut, throwsA(isA<StateError>()));
  });

  test('directAgent demuxes chunks by questionId', () async {
    await completeHandshake();
    final run = bridge.directAgent(
      agentProviderId: 'client.demo_agent',
      text: 'hi',
      questionId: 'q-1',
      mcpProviderIds: const ['client.filesystem_local'],
    );
    final msg = await server.waitForType('direct_agent');
    expect(msg['agentProviderId'], 'client.demo_agent');
    expect(msg['questionId'], 'q-1');
    expect(msg['mcpProviderIds'], ['client.filesystem_local']);
    server.push({
      'type': 'chunk',
      'questionId': 'q-1',
      'stream': 'stdout',
      'text': 'Hel',
    });
    server.push({
      'type': 'chunk',
      'question_id': 'q-1',
      'stream': 'stdout',
      'text': 'lo',
    });
    server.push({
      'type': 'run_end',
      'questionId': 'q-1',
      'ok': true,
      'elapsedMs': 12,
    });
    final result = await run;
    expect(result['ok'], isTrue);
    expect(result['text'], 'Hello');
    expect(result['questionId'], 'q-1');
  });

  test('directAgent fails on run_end ok=false', () async {
    await completeHandshake();
    final run = bridge.directAgent(
      agentProviderId: 'client.demo_agent',
      text: 'x',
      questionId: 'q-err',
    );
    await server.waitForType('direct_agent');
    server.push({
      'type': 'run_end',
      'questionId': 'q-err',
      'ok': false,
      'error': 'boom',
    });
    await expectLater(run, throwsA(isA<StateError>()));
  });

  test('mcp_tunnel_request unknown path → 404 or 503', () async {
    await completeHandshake();
    server.clientMessages.clear();
    server.push({
      'type': 'mcp_tunnel_request',
      'requestId': 'r1',
      'tunnelPath': 'filesystem',
      'method': 'POST',
      'path': '/mcp',
      'headers': <String, String>{},
      'bodyBase64': '',
    });
    final resp = await server.waitForType('mcp_tunnel_response');
    expect(resp['requestId'], 'r1');
    expect(resp['status'], anyOf(404, 503));
  });

  test('mcp_tunnel_request forwards to attached alias', () async {
    final http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() async => http.close(force: true));
    http.listen((req) async {
      req.response.statusCode = 200;
      req.response.write('{"ok":true}');
      await req.response.close();
    });

    await completeHandshake(
      bootstrap: _StaticBootstrap(
        SessionMcpBootstrapResult(
          filesystemActive: true,
          mcps: [
            sessionTunnelMcpEntry(
              clientId: clientFilesystemMcpId,
              description: 'docs',
              alias: filesystemTunnelAlias,
            ),
          ],
        ),
      ),
    );
    bridge.mcpHost.attachLoopbackAlias(filesystemTunnelAlias, http.port);

    server.clientMessages.clear();
    server.push({
      'type': 'mcp_tunnel_request',
      'requestId': 'r2',
      'tunnelPath': filesystemTunnelAlias,
      'method': 'POST',
      'path': '/mcp',
      'headers': {'content-type': 'application/json'},
      'bodyBase64': base64Encode(utf8.encode('{"m":1}')),
    });
    final resp = await server.waitForType('mcp_tunnel_response');
    expect(resp['requestId'], 'r2');
    expect(resp['status'], 200);
    final body = utf8.decode(base64Decode(resp['bodyBase64'] as String));
    expect(body, contains('ok'));
  });

  test('stop clears overlay remotely', () async {
    await completeHandshake();
    server.clientMessages.clear();
    final stopFut = bridge.stop(clearRemote: true);
    final clear = await server.waitForType('session_overlay_clear');
    expect(clear['type'], 'session_overlay_clear');
    server.push({'type': 'session_overlay_cleared'});
    await stopFut;
    expect(bridge.state, SessionBridgeState.idle);
    expect(bridge.registeredAgentIds, isEmpty);
  });
}
