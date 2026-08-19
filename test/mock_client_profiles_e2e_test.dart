import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ao_reach/ao_reach.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/io.dart';

String get _fixtureRoot =>
    '${Directory.current.path}${Platform.pathSeparator}test${Platform.pathSeparator}fixtures';
String get _echoProject =>
    '$_fixtureRoot${Platform.pathSeparator}custom_tools${Platform.pathSeparator}echo_tool';

Map<String, dynamic> echoManifest(String toolId) => {
      'contractVersion': '1',
      'toolId': toolId,
      'toolVersion': '0.1.0',
      'runtime': 'python',
      'wheel': 'echo_tool-0.1.0-py3-none-any.whl',
      'entrypoints': {'mcp': 'echo_tool.mcp:main'},
      'requiredEnv': <String>[],
      'permissions': {'filesystem': <String>[], 'network': false, 'env': <String>[]},
      'healthcheck': {'path': '/health', 'timeoutSeconds': 5},
      'fallbackPolicy': 'tunnel',
    };

class MockAoServer {
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
      if (req.uri.path == '/ws') {
        final ws = await WebSocketTransformer.upgrade(req);
        _socket = ws;
        ws.listen((raw) {
          clientMessages.add(jsonDecode(raw as String) as Map<String, dynamic>);
          _msgController.add(clientMessages.last);
        });
        return;
      }
      if (req.method == 'POST' && req.uri.path == '/api/v1/custom-tools/upload') {
        await req.fold<List<int>>(<int>[], (p, e) => p..addAll(e));
        req.response.statusCode = 200;
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode({'status': 'uploaded'}));
        await req.response.close();
        return;
      }
      if (req.method == 'POST' && req.uri.path == '/api/v1/custom-tools/activate') {
        final body = await utf8.decodeStream(req);
        final payload = jsonDecode(body) as Map<String, dynamic>;
        final toolId = payload['toolId']?.toString() ?? '';
        req.response.statusCode = 200;
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode({
          'ok': true,
          'mcp': {
            'id': toolId,
            'description': 'mock sandbox MCP',
            'streamable_http': {
              'url': '$httpBase/sandbox/$toolId/mcp',
              'headers': {'Accept': 'application/json, text/event-stream'},
            },
          },
        }));
        await req.response.close();
        return;
      }
      req.response.statusCode = 404;
      await req.response.close();
    });
  }

  Future<void> dispose() async {
    await _socket?.close();
    await _server?.close(force: true);
    await _msgController.close();
  }

  void push(Map<String, dynamic> msg) => _socket?.add(jsonEncode(msg));

  Future<void> waitUntilConnected() async {
    final deadline = DateTime.now().add(const Duration(seconds: 2));
    while (_socket == null) {
      if (DateTime.now().isAfter(deadline)) {
        throw TimeoutException('WS client never connected');
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  Future<Map<String, dynamic>> waitForType(String type) async {
    for (final m in clientMessages) {
      if (m['type'] == type) return m;
    }
    return _msgController.stream.firstWhere((m) => m['type'] == type);
  }
}

Future<void> completeHandshake({
  required SessionBridge bridge,
  required MockAoServer server,
  required String overlayRoot,
  required ReachConnectionConfig config,
  SessionMcpBootstrap? bootstrap,
}) async {
  final startFuture = bridge.start(
    config: config,
    overlayRoot: overlayRoot,
    mcpBootstrap: bootstrap ?? const EmptySessionMcpBootstrap(),
  );
  await server.waitUntilConnected();
  server.push({
    'type': 'hello',
    'sessionOverlay': true,
    'mcpTunnel': true,
    'customToolSandbox': true,
  });
  final reg = await server.waitForType('session_overlay_register');
  server.push({
    'type': 'session_overlay_ack',
    'agentIds': (reg['agents'] as List).map((a) => (a as Map)['id']).toList(),
    'mcpIds': (reg['mcps'] as List).map((m) => (m as Map)['id']).toList(),
    'expiresAt': 9999999999.0,
  });
  await startFuture;
}

class _FailingDeployClient extends ReachSandboxDeployClient {
  @override
  Future<SandboxDeployResult> uploadAndActivate(
    ReachConnectionConfig config,
    CustomToolBundle bundle, {
    Map<String, String>? env,
  }) {
    throw StateError('sandbox unavailable');
  }
}

void main() {
  group('custom tool contract', () {
    test('validateManifestMap accepts echo fixture manifest', () {
      final m = echoManifest('client.mock_comstar.fake_lsp_bridge');
      expect(() => validateManifestMap(m), returnsNormally);
    });
  });

  group('mock client profiles e2e', () {
    late MockAoServer server;
    late SessionBridge bridge;
    late Directory tempDir;

    setUp(() async {
      server = MockAoServer();
      await server.start();
      tempDir = await Directory.systemTemp.createTemp('ao_reach_mock_profile_');
      final agents = Directory('${tempDir.path}${Platform.pathSeparator}agent_providers');
      await agents.create(recursive: true);
      for (final name in ['demo_agent.yaml', 'demo_agent_b.yaml']) {
        await File('$_fixtureRoot${Platform.pathSeparator}agent_providers${Platform.pathSeparator}$name')
            .copy('${agents.path}${Platform.pathSeparator}$name');
      }
      bridge = SessionBridge(
        wsConnect: (uri, {protocols, headers, pingInterval, connectTimeout}) {
          return IOWebSocketChannel.connect(server.wsUri, headers: headers);
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

    test('mock-comstar sandbox deploy uploads without client MCP register', () async {
      final toolId = 'client.mock_comstar.fake_lsp_bridge';
      final bootstrap = HybridSessionMcpBootstrap(
        tools: [
          CustomToolDeploySpec(
            toolId: toolId,
            description: 'Mock LSP bridge',
            manifest: echoManifest(toolId),
            projectDir: _echoProject,
          ),
        ],
      );
      final config = ReachConnectionConfig(
        baseUrl: server.httpBase,
        headers: const {'x-agentic-user-name': 'tester', 'x-agentic-session-id': 's1'},
        appId: 'mock-comstar',
        deployToAoSandbox: true,
      );
      await completeHandshake(
        bridge: bridge,
        server: server,
        overlayRoot: tempDir.path,
        config: config,
        bootstrap: bootstrap,
      );
      expect(bridge.registeredMcpIds, isEmpty);
      expect(bridge.clientMcpWarnings, isEmpty);
      expect(
        server.clientMessages.any((m) => m['type'] == 'session_overlay_register'),
        isTrue,
      );
      final reg = server.clientMessages
          .firstWhere((m) => m['type'] == 'session_overlay_register');
      expect((reg['mcps'] as List?) ?? const [], isEmpty);
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('legacy mode skips sandbox when deployToAoSandbox false', () async {
      final bootstrap = HybridSessionMcpBootstrap(
        tools: mockProfileTools('mock-continue'),
      );
      final config = ReachConnectionConfig(
        baseUrl: server.httpBase,
        headers: const {'x-agentic-user-name': 'tester', 'x-agentic-session-id': 's2'},
        appId: 'mock-continue',
        deployToAoSandbox: false,
      );
      await completeHandshake(
        bridge: bridge,
        server: server,
        overlayRoot: tempDir.path,
        config: config,
        bootstrap: bootstrap,
      );
      expect(bridge.registeredMcpIds, isEmpty);
    });

    test('sandbox failure falls back to tunnel with warning', () async {
      final toolId = 'client.mock_ha.fake_entity_registry';
      final host = LocalMcpHost();
      host.attachLoopbackAlias('fake_entity_registry', 19002);
      final bootstrap = HybridSessionMcpBootstrap(
        tools: [
          CustomToolDeploySpec(
            toolId: toolId,
            description: 'Mock HA entity registry',
            manifest: echoManifest(toolId),
            projectDir: _echoProject,
            alias: 'fake_entity_registry',
          ),
        ],
        deployClient: _FailingDeployClient(),
      );
      final config = ReachConnectionConfig(
        baseUrl: server.httpBase,
        headers: const {},
        appId: 'mock-ha',
        deployToAoSandbox: true,
      );
      final result = await bootstrap.prepare(
        host,
        mcpTunnel: true,
        config: config,
        customToolSandbox: true,
      );
      expect(result.warnings.any((w) => w.contains('tunnel fallback')), isTrue);
      expect(
        (result.mcps.single['streamable_http'] as Map)['url'],
        'tunnel://session-mcp/fake_entity_registry',
      );
      await host.stop();
    });

    for (final profile in ['mock-comstar', 'mock-continue', 'mock-ha']) {
      test('mock profile $profile exposes fictional tool ids', () {
        final tools = mockProfileTools(profile);
        expect(tools, isNotEmpty);
        for (final t in tools) {
          expect(t.toolId.startsWith('client.'), isTrue);
        }
      });
    }
  });
}
