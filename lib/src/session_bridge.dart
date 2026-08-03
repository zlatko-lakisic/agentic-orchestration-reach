import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'connection_config.dart';
import 'ids.dart';
import 'local_mcp_host.dart';
import 'mcp_bootstrap.dart';
import 'overlay_packer.dart';
import 'speech_client.dart';

enum SessionBridgeState {
  idle,
  connecting,
  active,
  disconnected,
  failed,
}

/// Factory for the session WebSocket (injectable for tests).
typedef ReachWsConnect = WebSocketChannel Function(
  Uri uri, {
  Iterable<String>? protocols,
  Map<String, dynamic>? headers,
  Duration? pingInterval,
  Duration? connectTimeout,
});

/// Remote AO session overlay + MCP tunnel client (AO v1.27+).
///
/// Opens `/ws` with caller-supplied headers, registers `client.*` agents via
/// [OverlayPacker], answers `mcp_tunnel_request`, and runs `direct_agent` on
/// the owning socket. When AO ≥ 1.28 advertises `speech` on hello, use
/// [speechClient] for OpenAI-compatible STT/TTS HTTP (sidecars — not WS).
class SessionBridge {
  SessionBridge({
    OverlayPacker? packer,
    LocalMcpHost? mcpHost,
    ReachWsConnect? wsConnect,
  })  : _packer = packer ?? OverlayPacker(),
        _mcpHost = mcpHost ?? LocalMcpHost(),
        _wsConnect = wsConnect ?? _defaultWsConnect;

  final OverlayPacker _packer;
  final LocalMcpHost _mcpHost;
  final ReachWsConnect _wsConnect;

  WebSocketChannel? _channel;
  StreamSubscription? _sub;
  Completer<Map<String, dynamic>>? _helloWait;
  Completer<Map<String, dynamic>>? _ackWait;
  Completer<Map<String, dynamic>>? _clearedWait;
  bool _stopping = false;
  final Map<String, _PendingDirectRun> _pendingRuns = {};
  SpeechClient? _speechClient;

  SessionBridgeState state = SessionBridgeState.idle;
  String? error;
  bool sessionOverlay = false;
  bool mcpTunnel = false;
  SpeechCapabilities? speech;
  List<String> registeredAgentIds = const [];
  List<String> registeredMcpIds = const [];
  double? expiresAt;
  bool filesystemMcpActive = false;
  bool emailGmailMcpActive = false;
  bool calendarGoogleMcpActive = false;

  /// Bare ids of Tools MCPs successfully started as stdio tunnels this session.
  List<String> activeTunnelBareIds = const [];

  /// Soft-fail notes for optional client MCPs.
  List<String> clientMcpWarnings = const [];

  /// Last AO stderr progress line while waiting for overlay ack (model pulls).
  String? registerProgress;
  int _reconnectAttempts = 0;
  ReachConnectionConfig? _lastConfig;
  String? _lastOverlayRoot;
  SessionMcpBootstrap? _lastBootstrap;

  final _statusController = StreamController<SessionBridge>.broadcast();
  Stream<SessionBridge> get statusChanges => _statusController.stream;

  bool get isActive => state == SessionBridgeState.active;
  String? get filesystemMcpId => filesystemMcpActive ? clientFilesystemMcpId : null;
  String? get emailGmailMcpId => emailGmailMcpActive ? clientEmailGmailMcpId : null;
  String? get calendarGoogleMcpId =>
      calendarGoogleMcpActive ? clientCalendarGoogleMcpId : null;

  LocalMcpHost get mcpHost => _mcpHost;

  /// Non-null when the remote AO advertised speech sidecars on `hello`.
  SpeechClient? get speechClient => _speechClient;

  /// Run `direct_agent` on the owning session WebSocket.
  Future<Map<String, dynamic>> directAgent({
    required String agentProviderId,
    required String text,
    String context = '',
    String? questionId,
    Map<String, dynamic>? responseFormat,
    Map<String, dynamic>? jsonSchema,
    List<String>? mcpProviderIds,
    Duration timeout = const Duration(minutes: 5),
  }) async {
    if (!isActive || _channel == null) {
      throw StateError('Session bridge is not active — cannot run client.* agents');
    }
    final prefix = _lastConfig?.questionIdPrefix ?? 'reach';
    final qid = (questionId != null && questionId.trim().isNotEmpty)
        ? questionId.trim()
        : '$prefix-${DateTime.now().microsecondsSinceEpoch}';
    if (_pendingRuns.containsKey(qid)) {
      throw StateError('direct_agent already in flight for questionId=$qid');
    }
    final pending = _PendingDirectRun(questionId: qid);
    _pendingRuns[qid] = pending;
    _send({
      'type': 'direct_agent',
      'agentProviderId': agentProviderId,
      'text': text,
      'context': context,
      'questionId': qid,
      if (responseFormat != null) 'responseFormat': responseFormat,
      if (jsonSchema != null) 'jsonSchema': jsonSchema,
      if (mcpProviderIds != null && mcpProviderIds.isNotEmpty) 'mcpProviderIds': mcpProviderIds,
    });
    try {
      return await pending.done.future.timeout(timeout);
    } on TimeoutException {
      _pendingRuns.remove(qid);
      throw TimeoutException('direct_agent timed out for $agentProviderId ($qid)');
    }
  }

  void _emit() {
    if (!_statusController.isClosed) _statusController.add(this);
  }

  /// Connect, bootstrap client MCPs, register session overlay.
  Future<void> start({
    required ReachConnectionConfig config,
    required String overlayRoot,
    SessionMcpBootstrap mcpBootstrap = const EmptySessionMcpBootstrap(),
  }) async {
    await stop(clearRemote: false);
    _stopping = false;
    if (!config.enabled) {
      state = SessionBridgeState.idle;
      error = null;
      _emit();
      return;
    }

    state = SessionBridgeState.connecting;
    error = null;
    registerProgress = null;
    _lastConfig = config;
    _lastOverlayRoot = overlayRoot;
    _lastBootstrap = mcpBootstrap;
    _emit();

    try {
      await _connectAndRegister(
        config: config,
        overlayRoot: overlayRoot,
        mcpBootstrap: mcpBootstrap,
      );
      _reconnectAttempts = 0;
    } catch (e) {
      state = SessionBridgeState.failed;
      error = e.toString();
      await _cleanupLocal(clearRemote: false);
      _emit();
      rethrow;
    }
  }

  Future<void> _connectAndRegister({
    required ReachConnectionConfig config,
    required String overlayRoot,
    required SessionMcpBootstrap mcpBootstrap,
  }) async {
    final wsUrl = reachWsUri(config.baseUrl);
    final headers = Map<String, dynamic>.from(config.headers);
    // WebSocket handshake: drop Accept: application/json (some proxies are picky).
    headers.remove('Accept');

    final helloWait = Completer<Map<String, dynamic>>();
    _helloWait = helloWait;

    final channel = _wsConnect(
      wsUrl,
      headers: headers,
      pingInterval: const Duration(seconds: 20),
    );
    _channel = channel;
    _sub = channel.stream.listen(
      _onMessage,
      onError: (Object e, StackTrace st) {
        unawaited(_onSocketLost(
          'WebSocket error: $e',
          config: config,
          overlayRoot: overlayRoot,
          mcpBootstrap: mcpBootstrap,
        ));
      },
      onDone: () {
        unawaited(_onSocketLost(
          'session tools disconnected',
          config: config,
          overlayRoot: overlayRoot,
          mcpBootstrap: mcpBootstrap,
        ));
      },
      cancelOnError: true,
    );

    final hello = await helloWait.future.timeout(
      const Duration(seconds: 15),
      onTimeout: () => throw TimeoutException('Timed out waiting for AO hello'),
    );
    if (hello['type'] != 'hello') {
      throw StateError('Expected hello, got ${hello['type']}');
    }
    sessionOverlay = hello['sessionOverlay'] == true;
    mcpTunnel = hello['mcpTunnel'] == true;
    _disposeSpeechClient();
    speech = SpeechCapabilities.tryParse(hello['speech']);
    if (speech != null) {
      _speechClient = SpeechClient(
        capabilities: speech!,
        headers: config.headers,
        speechToken: config.speechToken,
      );
    }
    if (!sessionOverlay) {
      throw StateError(
        'Remote AO does not advertise sessionOverlay '
        '(set AGENTIC_SERVE_SESSION_OVERLAY=1 on the shared host, AO ≥ v1.27.0).',
      );
    }

    final boot = await mcpBootstrap.prepare(_mcpHost, mcpTunnel: mcpTunnel);
    if (boot.mcps.isNotEmpty && !mcpTunnel) {
      final needsTunnel = boot.mcps.any((m) {
        final http = m['streamable_http'];
        if (http is! Map) return false;
        final url = http['url']?.toString() ?? '';
        return url.startsWith('tunnel://');
      });
      if (needsTunnel) {
        throw StateError(
          'Client MCP tunnel needs AGENTIC_SERVE_MCP_TUNNEL=1 on the shared host '
          '(or disable tunnel-backed client MCPs).',
        );
      }
    }

    filesystemMcpActive = boot.filesystemActive;
    emailGmailMcpActive = boot.emailGmailActive;
    calendarGoogleMcpActive = boot.calendarGoogleActive;
    activeTunnelBareIds = List.unmodifiable(boot.activeTunnelBareIds);
    clientMcpWarnings = List.unmodifiable(boot.warnings);

    final pack = await _packer.pack(
      overlayRoot: overlayRoot,
      extraMcps: boot.mcps,
    );

    final ackWait = Completer<Map<String, dynamic>>();
    _ackWait = ackWait;
    registerProgress = 'Registering session agents on AO…';
    _emit();
    _send({
      'type': 'session_overlay_register',
      'ttlSeconds': config.ttlSeconds,
      'agents': pack.agents,
      'mcps': pack.mcps,
      'skills': pack.skills,
    });

    final ack = await ackWait.future.timeout(
      const Duration(minutes: 45),
      onTimeout: () => throw TimeoutException(
        'Timed out waiting for session_overlay_ack '
        '(engine may still be downloading models)',
      ),
    );
    if (ack['type'] == 'error') {
      throw StateError(ack['message']?.toString() ?? 'session_overlay_register failed');
    }
    if (ack['type'] != 'session_overlay_ack') {
      throw StateError('Expected session_overlay_ack, got ${ack['type']}');
    }

    registeredAgentIds =
        ((ack['agentIds'] as List?) ?? pack.agentIds).map((e) => e.toString()).toList();
    if (ack.containsKey('mcpIds')) {
      registeredMcpIds =
          ((ack['mcpIds'] as List?) ?? const []).map((e) => e.toString()).toList();
    } else {
      registeredMcpIds = List<String>.from(pack.mcpIds);
    }
    if (!registeredMcpIds.contains(clientFilesystemMcpId)) {
      filesystemMcpActive = false;
    }
    if (!registeredMcpIds.contains(clientEmailGmailMcpId)) {
      emailGmailMcpActive = false;
    }
    if (!registeredMcpIds.contains(clientCalendarGoogleMcpId)) {
      calendarGoogleMcpActive = false;
    }
    activeTunnelBareIds = activeTunnelBareIds
        .where((bare) => registeredMcpIds.contains(toClientAgentId(bare)))
        .toList(growable: false);
    final exp = ack['expiresAt'];
    expiresAt = exp is num ? exp.toDouble() : null;
    registerProgress = null;
    state = SessionBridgeState.active;
    error = null;
    _emit();
  }

  Future<void> _onSocketLost(
    String reason, {
    required ReachConnectionConfig config,
    required String overlayRoot,
    required SessionMcpBootstrap mcpBootstrap,
  }) async {
    if (_stopping) return;
    if (state == SessionBridgeState.idle || state == SessionBridgeState.failed) return;
    final wasActive =
        state == SessionBridgeState.active || state == SessionBridgeState.connecting;
    await _cleanupLocal(clearRemote: false);
    if (!wasActive) return;

    final max = config.maxReconnectAttempts;
    if (_reconnectAttempts < max &&
        config.enabled &&
        _lastConfig != null &&
        _lastOverlayRoot != null &&
        _lastBootstrap != null) {
      _reconnectAttempts++;
      state = SessionBridgeState.connecting;
      error = '$reason — retrying once…';
      _emit();
      try {
        await _connectAndRegister(
          config: _lastConfig!,
          overlayRoot: _lastOverlayRoot!,
          mcpBootstrap: _lastBootstrap!,
        );
        _reconnectAttempts = 0;
        return;
      } catch (e) {
        state = SessionBridgeState.disconnected;
        error = 'Session tools disconnected (retry failed): $e';
        _emit();
        return;
      }
    }

    state = SessionBridgeState.disconnected;
    error = reason;
    _emit();
  }

  void _onMessage(dynamic raw) {
    Map<String, dynamic>? msg;
    try {
      if (raw is String) {
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, dynamic>) {
          msg = decoded;
        } else if (decoded is Map) {
          msg = Map<String, dynamic>.from(decoded);
        }
      } else if (raw is Map<String, dynamic>) {
        msg = raw;
      } else if (raw is Map) {
        msg = Map<String, dynamic>.from(raw);
      }
    } catch (_) {
      return;
    }
    if (msg == null) return;

    final type = msg['type']?.toString() ?? '';
    switch (type) {
      case 'hello':
        _helloWait?.complete(msg);
        _helloWait = null;
        break;
      case 'session_overlay_ack':
        _ackWait?.complete(msg);
        _ackWait = null;
        break;
      case 'session_overlay_cleared':
        _clearedWait?.complete(msg);
        _clearedWait = null;
        break;
      case 'chunk':
        if (_ackWait != null && !(_ackWait!.isCompleted)) {
          final text = (msg['text']?.toString() ?? '').trim();
          if (text.isNotEmpty) {
            registerProgress = text.replaceFirst(RegExp(r'^\(engine\)\s*'), '');
            _emit();
          }
        }
        _onRunChunk(msg);
        break;
      case 'run_end':
        _onRunEnd(msg);
        break;
      case 'error':
        if (_ackWait != null && !(_ackWait!.isCompleted)) {
          _ackWait!.complete(msg);
          _ackWait = null;
        } else if (_helloWait != null && !(_helloWait!.isCompleted)) {
          _helloWait!.completeError(StateError(msg['message']?.toString() ?? 'AO error'));
          _helloWait = null;
        } else {
          _onRunError(msg);
        }
        break;
      case 'mcp_tunnel_request':
        unawaited(_handleTunnelRequest(msg));
        break;
      case 'pong':
      case 'preflight':
      case 'run_start':
        break;
      default:
        break;
    }
  }

  void _onRunChunk(Map<String, dynamic> msg) {
    final qid = msg['question_id']?.toString() ?? msg['questionId']?.toString();
    if (qid == null) return;
    final run = _pendingRuns[qid];
    if (run == null) return;
    if ((msg['stream']?.toString() ?? 'stdout') == 'stdout') {
      run.stdout.write(msg['text']?.toString() ?? '');
    }
  }

  void _onRunError(Map<String, dynamic> msg) {
    final qid = msg['question_id']?.toString() ?? msg['questionId']?.toString();
    if (qid == null) return;
    final run = _pendingRuns[qid];
    if (run == null) return;
    run.lastError = msg['message']?.toString() ?? 'AO error';
  }

  void _onRunEnd(Map<String, dynamic> msg) {
    final qid = msg['question_id']?.toString() ?? msg['questionId']?.toString();
    if (qid == null) return;
    final run = _pendingRuns.remove(qid);
    if (run == null || run.done.isCompleted) return;
    final text = run.stdout.toString();
    final fallback = msg['text']?.toString() ?? '';
    final ok = msg['ok'] == true;
    final err = msg['error']?.toString() ?? run.lastError;
    if (!ok) {
      run.done.completeError(
        StateError(err?.isNotEmpty == true ? err! : 'direct_agent failed (run_end ok=false)'),
      );
      return;
    }
    run.done.complete({
      'ok': true,
      'text': text.isNotEmpty ? text : fallback,
      'elapsedMs': msg['elapsedMs'],
      'questionId': qid,
    });
  }

  Future<void> _handleTunnelRequest(Map<String, dynamic> msg) async {
    final requestId = msg['requestId']?.toString() ?? '';
    if (requestId.isEmpty) return;
    if (!_mcpHost.isRunning) {
      _send({
        'type': 'mcp_tunnel_response',
        'requestId': requestId,
        'status': 503,
        'headers': {'content-type': 'application/json'},
        'bodyBase64': base64Encode(
          utf8.encode(jsonEncode({'error': 'local client MCP is not running'})),
        ),
      });
      return;
    }

    final tunnelPath = msg['tunnelPath']?.toString() ?? '';
    if (!_mcpHost.isAliasRunning(tunnelPath)) {
      _send({
        'type': 'mcp_tunnel_response',
        'requestId': requestId,
        'status': 404,
        'headers': {'content-type': 'application/json'},
        'bodyBase64': base64Encode(
          utf8.encode(jsonEncode({'error': 'unknown tunnelPath $tunnelPath'})),
        ),
      });
      return;
    }

    try {
      final method = (msg['method']?.toString() ?? 'POST').toUpperCase();
      final path = msg['path']?.toString() ?? '/mcp';
      final headersRaw = msg['headers'];
      final headers = <String, String>{};
      if (headersRaw is Map) {
        headersRaw.forEach((k, v) {
          if (k != null && v != null) headers[k.toString()] = v.toString();
        });
      }
      final bodyB64 = msg['bodyBase64']?.toString() ?? '';
      final body = bodyB64.isEmpty ? <int>[] : base64Decode(bodyB64);
      final result = await _mcpHost.forward(
        alias: tunnelPath,
        method: method,
        path: path,
        headers: headers,
        body: body,
      );
      _send({
        'type': 'mcp_tunnel_response',
        'requestId': requestId,
        'status': result.status,
        'headers': result.headers,
        'bodyBase64': base64Encode(result.body),
      });
    } catch (e) {
      _send({
        'type': 'mcp_tunnel_response',
        'requestId': requestId,
        'status': 502,
        'headers': {'content-type': 'application/json'},
        'bodyBase64': base64Encode(
          utf8.encode(jsonEncode({'error': 'tunnel proxy failed: $e'})),
        ),
      });
    }
  }

  void _send(Map<String, dynamic> payload) {
    final ch = _channel;
    if (ch == null) return;
    ch.sink.add(jsonEncode(payload));
  }

  Future<void> stop({bool clearRemote = true}) async {
    _stopping = true;
    await _cleanupLocal(clearRemote: clearRemote);
    state = SessionBridgeState.idle;
    registeredAgentIds = const [];
    registeredMcpIds = const [];
    expiresAt = null;
    filesystemMcpActive = false;
    emailGmailMcpActive = false;
    calendarGoogleMcpActive = false;
    activeTunnelBareIds = const [];
    clientMcpWarnings = const [];
    speech = null;
    error = null;
    _reconnectAttempts = 0;
    _emit();
  }

  void _disposeSpeechClient() {
    try {
      _speechClient?.close();
    } catch (_) {}
    _speechClient = null;
  }

  Future<void> _cleanupLocal({required bool clearRemote}) async {
    for (final run in _pendingRuns.values) {
      if (!run.done.isCompleted) {
        run.done.completeError(StateError('session bridge closed'));
      }
    }
    _pendingRuns.clear();
    if (clearRemote && _channel != null) {
      try {
        final cleared = Completer<Map<String, dynamic>>();
        _clearedWait = cleared;
        _send({'type': 'session_overlay_clear'});
        await cleared.future.timeout(const Duration(seconds: 5));
      } catch (_) {}
    }
    try {
      await _sub?.cancel();
    } catch (_) {}
    _sub = null;
    try {
      await _channel?.sink.close();
    } catch (_) {}
    _channel = null;
    _helloWait = null;
    _ackWait = null;
    _clearedWait = null;
    try {
      await _mcpHost.stop();
    } catch (_) {}
    _disposeSpeechClient();
    filesystemMcpActive = false;
    emailGmailMcpActive = false;
    calendarGoogleMcpActive = false;
    activeTunnelBareIds = const [];
    clientMcpWarnings = const [];
  }

  Future<void> dispose() async {
    await stop(clearRemote: true);
    await _statusController.close();
  }

  static WebSocketChannel _defaultWsConnect(
    Uri uri, {
    Iterable<String>? protocols,
    Map<String, dynamic>? headers,
    Duration? pingInterval,
    Duration? connectTimeout,
  }) {
    return IOWebSocketChannel.connect(
      uri,
      protocols: protocols,
      headers: headers,
      pingInterval: pingInterval,
      connectTimeout: connectTimeout,
    );
  }
}

class _PendingDirectRun {
  _PendingDirectRun({required this.questionId});

  final String questionId;
  final StringBuffer stdout = StringBuffer();
  final Completer<Map<String, dynamic>> done = Completer<Map<String, dynamic>>();
  String? lastError;
}
