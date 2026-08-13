import 'dart:io';
import 'dart:math';

import 'mtls.dart';

/// Stable client id pattern for Reach `appId` (e.g. `myapp`, `field-client`).
final RegExp reachAppIdPattern = RegExp(r'^[a-z][a-z0-9_-]{1,63}$');

/// Normalize and validate a Reach [appId].
///
/// Throws [ArgumentError] when empty or not matching [reachAppIdPattern].
String normalizeReachAppId(String raw) {
  final appId = raw.trim().toLowerCase();
  if (appId.isEmpty) {
    throw ArgumentError.value(
      raw,
      'appId',
      'ReachConnectionConfig.appId is required '
          "(clients must advertise a stable id such as 'myapp' or 'field-client')",
    );
  }
  if (!reachAppIdPattern.hasMatch(appId)) {
    throw ArgumentError.value(
      raw,
      'appId',
      'must match ${reachAppIdPattern.pattern}',
    );
  }
  return appId;
}

/// Connection settings for AO Reach (product apps map their own settings here).
class ReachConnectionConfig {
  ReachConnectionConfig({
    required this.baseUrl,
    required this.headers,
    required String appId,
    this.enabled = true,
    this.ttlSeconds = 3600,
    this.questionIdPrefix = 'reach',
    this.maxReconnectAttempts = 1,
    this.speechToken,
    this.speechSttBaseUrlOverride,
    this.speechTtsBaseUrlOverride,
    this.mtls,
    this.dynamicPlanning = false,
    this.defaultRunMode = 'dynamic',
    this.sessionEnv,
    this.allowedAgentProviderIds,
  }) : appId = normalizeReachAppId(appId);

  /// HTTP(S) base URL of the AO engine (e.g. `https://ao-host:8765`).
  ///
  /// Reach talks to the engine directly — not via Warpgate. Use `https` when
  /// [mtls] is set.
  final String baseUrl;

  /// Headers for REST + WebSocket handshake (optional session id, etc.).
  /// Under mTLS, user identity comes from the client certificate.
  final Map<String, String> headers;

  /// Stable product identity sent on every `session_overlay_register`
  /// (e.g. `myapp`, `field-client`). Required by AO ≥ 1.31.
  final String appId;

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

  /// When true, [SessionBridge.chat] is the preferred path for this app
  /// (sticky default). Per-call [SessionBridge.chat] always works regardless.
  final bool dynamicPlanning;

  /// Default `runMode` for [SessionBridge.chat] when the caller omits one
  /// (`dynamic` or `dynamic-iterative`).
  final String defaultRunMode;

  /// Provider secrets / base URLs sent on `session_overlay_register` (`env`).
  /// Allowed keys: OPENAI_API_KEY, ANTHROPIC_API_KEY, HF_TOKEN, base URLs, …
  final Map<String, String>? sessionEnv;

  /// Optional stock agent allowlist for this session (``client.*`` always kept).
  final List<String>? allowedAgentProviderIds;

  ReachConnectionConfig copyWith({
    String? baseUrl,
    Map<String, String>? headers,
    String? appId,
    bool? enabled,
    int? ttlSeconds,
    String? questionIdPrefix,
    int? maxReconnectAttempts,
    String? speechToken,
    String? speechSttBaseUrlOverride,
    String? speechTtsBaseUrlOverride,
    ReachMtlsConfig? mtls,
    bool? dynamicPlanning,
    String? defaultRunMode,
    Map<String, String>? sessionEnv,
    List<String>? allowedAgentProviderIds,
  }) {
    return ReachConnectionConfig(
      baseUrl: baseUrl ?? this.baseUrl,
      headers: headers ?? Map<String, String>.from(this.headers),
      appId: appId ?? this.appId,
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
      dynamicPlanning: dynamicPlanning ?? this.dynamicPlanning,
      defaultRunMode: defaultRunMode ?? this.defaultRunMode,
      sessionEnv: sessionEnv ?? this.sessionEnv,
      allowedAgentProviderIds:
          allowedAgentProviderIds ?? this.allowedAgentProviderIds,
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
