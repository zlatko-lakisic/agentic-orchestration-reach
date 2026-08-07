import 'dart:io';
import 'dart:math';

import 'mtls.dart';

/// Connection settings for AO Reach (product apps map their own settings here).
class ReachConnectionConfig {
  const ReachConnectionConfig({
    required this.baseUrl,
    required this.headers,
    this.enabled = true,
    this.ttlSeconds = 3600,
    this.questionIdPrefix = 'reach',
    this.maxReconnectAttempts = 1,
    this.speechToken,
    this.speechSttBaseUrlOverride,
    this.speechTtsBaseUrlOverride,
    this.mtls,
  });

  /// HTTP(S) base URL of the AO engine (e.g. `https://ao-host:8765`).
  ///
  /// Reach talks to the engine directly — not via Warpgate. Use `https` when
  /// [mtls] is set.
  final String baseUrl;

  /// Headers for REST + WebSocket handshake (optional session id, etc.).
  /// Under mTLS, user identity comes from the client certificate.
  final Map<String, String> headers;

  /// When false, [SessionBridge.start] is a no-op (idle).
  final bool enabled;

  /// Overlay TTL sent with `session_overlay_register`.
  final int ttlSeconds;

  /// Prefix for auto-generated `questionId` values in [SessionBridge.directAgent].
  final String questionIdPrefix;

  /// How many times to retry after a socket drop while active/connecting.
  final int maxReconnectAttempts;

  /// Optional bearer for AO speech sidecars (`AGENTIC_SPEECH_TOKEN`).
  final String? speechToken;

  /// When non-empty, replace advertised STT base URL after hello parse.
  final String? speechSttBaseUrlOverride;

  /// When non-empty, replace advertised TTS base URL after hello parse.
  final String? speechTtsBaseUrlOverride;

  /// Mutual TLS material for the engine WebSocket (and speech HTTP when set).
  final ReachMtlsConfig? mtls;

  ReachConnectionConfig copyWith({
    String? baseUrl,
    Map<String, String>? headers,
    bool? enabled,
    int? ttlSeconds,
    String? questionIdPrefix,
    int? maxReconnectAttempts,
    String? speechToken,
    String? speechSttBaseUrlOverride,
    String? speechTtsBaseUrlOverride,
    ReachMtlsConfig? mtls,
  }) {
    return ReachConnectionConfig(
      baseUrl: baseUrl ?? this.baseUrl,
      headers: headers ?? Map<String, String>.from(this.headers),
      enabled: enabled ?? this.enabled,
      ttlSeconds: ttlSeconds ?? this.ttlSeconds,
      questionIdPrefix: questionIdPrefix ?? this.questionIdPrefix,
      maxReconnectAttempts: maxReconnectAttempts ?? this.maxReconnectAttempts,
      speechToken: speechToken ?? this.speechToken,
      speechSttBaseUrlOverride:
          speechSttBaseUrlOverride ?? this.speechSttBaseUrlOverride,
      speechTtsBaseUrlOverride:
          speechTtsBaseUrlOverride ?? this.speechTtsBaseUrlOverride,
      mtls: mtls ?? this.mtls,
    );
  }
}

/// Ensure identity header values exist for `AGENTIC_REQUIRE_IDENTITY` hosts.
({String userName, String sessionId}) ensureReachIdentity({
  required String userName,
  required String sessionId,
  String defaultUser = 'reach',
  String sessionPrefix = 'reach',
}) {
  var user = userName.trim();
  var session = sessionId.trim();
  if (user.isEmpty) {
    user = Platform.environment['USER'] ??
        Platform.environment['USERNAME'] ??
        defaultUser;
  }
  if (session.isEmpty) {
    final rand = Random.secure().nextInt(0x7fffffff).toRadixString(16);
    session = '$sessionPrefix-$rand';
  }
  return (userName: user, sessionId: session);
}

/// Build `ws://` / `wss://` `/ws` URI from an HTTP base URL.
Uri reachWsUri(String baseUrl) {
  final http = Uri.parse(baseUrl.replaceAll(RegExp(r'/+$'), ''));
  final scheme = http.scheme == 'https' ? 'wss' : 'ws';
  return http.replace(scheme: scheme, path: '/ws', query: null, fragment: null);
}
