import 'dart:convert';
import 'dart:io';

import 'package:ao_reach/ao_reach.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

void main() {
  test('ReachRunStatus.fromJson parses processing and phase', () {
    final s = ReachRunStatus.fromJson({
      'type': 'status',
      'processing': true,
      'phase': 'warming_agent',
      'message': 'Warming up gpt research…',
      'agentProviderId': 'gpt_research',
      'question_id': 'q1',
    });
    expect(s.processing, isTrue);
    expect(s.phase, 'warming_agent');
    expect(s.message, contains('gpt research'));
    expect(s.agentProviderId, 'gpt_research');
  });

  test('chat surfaces status callback and ReachRunException on failure', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() async => server.close(force: true));

    server.listen((req) async {
      if (req.uri.path != '/ws') {
        req.response.statusCode = 404;
        await req.response.close();
        return;
      }
      final socket = await WebSocketTransformer.upgrade(req);
      socket.add(jsonEncode({
        'type': 'hello',
        'sessionOverlay': true,
        'mcpTunnel': false,
        'protocol': 'engine-ws/1',
      }));
      await for (final raw in socket) {
        final msg = jsonDecode(raw as String) as Map<String, dynamic>;
        if (msg['type'] == 'session_overlay_register') {
          socket.add(jsonEncode({
            'type': 'session_overlay_ack',
            'agentIds': <String>[],
            'mcpIds': <String>[],
            'skillIds': <String>[],
            'expiresAt': DateTime.now().millisecondsSinceEpoch / 1000 + 3600,
          }));
        } else if (msg['type'] == 'chat') {
          final qid = msg['questionId'];
          socket.add(jsonEncode({
            'type': 'run_start',
            'mode': 'chat',
            'processing': true,
            'question_id': qid,
            'run_id': 'r1',
          }));
          socket.add(jsonEncode({
            'type': 'status',
            'processing': true,
            'phase': 'planning',
            'message': 'Planning the best approach…',
            'question_id': qid,
            'run_id': 'r1',
          }));
          socket.add(jsonEncode({
            'type': 'status',
            'processing': false,
            'phase': 'error',
            'message': 'Something went wrong.',
            'code': 'run_failed',
            'question_id': qid,
            'run_id': 'r1',
          }));
          socket.add(jsonEncode({
            'type': 'error',
            'message': 'Something went wrong.',
            'code': 'run_failed',
            'processing': false,
            'phase': 'error',
            'question_id': qid,
            'run_id': 'r1',
          }));
          socket.add(jsonEncode({
            'type': 'run_end',
            'ok': false,
            'exitCode': 1,
            'error': 'Something went wrong.',
            'code': 'run_failed',
            'processing': false,
            'question_id': qid,
            'run_id': 'r1',
          }));
        }
      }
    });

    final statuses = <ReachRunStatus>[];
    final bridge = SessionBridge(
      wsConnect: (uri, {protocols, headers, pingInterval, connectTimeout}) {
        return WebSocketChannel.connect(uri);
      },
    );
    final overlay = await Directory.systemTemp.createTemp('ao-reach-status-');
    addTearDown(() async => overlay.delete(recursive: true));
    final agents = Directory('${overlay.path}/agent_providers')
      ..createSync(recursive: true);
    File('${agents.path}/demo.yaml').writeAsStringSync('''
id: demo
type: ollama
role: tester
goal: test
model: tiny
''');

    await bridge.start(
      config: ReachConnectionConfig(
        baseUrl: 'http://127.0.0.1:${server.port}',
        headers: const {},
        appId: 'demo-app',
      ),
      overlayRoot: overlay.path,
    );

    try {
      await bridge.chat(
        text: 'hello',
        onStatus: statuses.add,
      );
      fail('expected ReachRunException');
    } on ReachRunException catch (e) {
      expect(e.code, 'run_failed');
      expect(e.message, 'Something went wrong.');
      expect(e.processing, isFalse);
    }

    expect(statuses.map((s) => s.phase), containsAll(['starting', 'planning', 'error']));
    expect(statuses.any((s) => s.processing), isTrue);
    expect(statuses.last.processing, isFalse);
    await bridge.dispose();
  });
}
