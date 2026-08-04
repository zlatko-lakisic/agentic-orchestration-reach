import 'dart:convert';

import 'package:http/http.dart' as http;

/// Speech endpoints advertised on AO engine WebSocket ``hello``.
class SpeechCapabilities {
  const SpeechCapabilities({
    required this.sttBaseUrl,
    required this.ttsBaseUrl,
    this.transcribePath = '/v1/audio/transcriptions',
    this.speechPath = '/v1/audio/speech',
    this.openaiCompatible = true,
    this.authBearer = false,
  });

  final String sttBaseUrl;
  final String ttsBaseUrl;
  final String transcribePath;
  final String speechPath;
  final bool openaiCompatible;
  final bool authBearer;

  /// Parse ``hello['speech']``; returns null when missing or disabled.
  static SpeechCapabilities? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final map = Map<String, dynamic>.from(raw);
    if (map['enabled'] == false) return null;
    final stt = map['sttBaseUrl']?.toString().trim() ?? '';
    final tts = map['ttsBaseUrl']?.toString().trim() ?? '';
    if (stt.isEmpty || tts.isEmpty) return null;
    final auth = map['auth']?.toString().toLowerCase();
    return SpeechCapabilities(
      sttBaseUrl: stt.replaceAll(RegExp(r'/+$'), ''),
      ttsBaseUrl: tts.replaceAll(RegExp(r'/+$'), ''),
      transcribePath: (map['transcribePath']?.toString().trim().isNotEmpty == true)
          ? map['transcribePath'].toString().trim()
          : '/v1/audio/transcriptions',
      speechPath: (map['speechPath']?.toString().trim().isNotEmpty == true)
          ? map['speechPath'].toString().trim()
          : '/v1/audio/speech',
      openaiCompatible: map['openaiCompatible'] != false,
      authBearer: auth == 'bearer',
    );
  }

  /// Replace base URLs when [sttBaseUrl] / [ttsBaseUrl] are non-empty after trim.
  SpeechCapabilities withOverrides({String? sttBaseUrl, String? ttsBaseUrl}) {
    String? normalize(String? raw) {
      final t = raw?.trim() ?? '';
      if (t.isEmpty) return null;
      return t.replaceAll(RegExp(r'/+$'), '');
    }

    final stt = normalize(sttBaseUrl);
    final tts = normalize(ttsBaseUrl);
    if (stt == null && tts == null) return this;
    return SpeechCapabilities(
      sttBaseUrl: stt ?? this.sttBaseUrl,
      ttsBaseUrl: tts ?? this.ttsBaseUrl,
      transcribePath: transcribePath,
      speechPath: speechPath,
      openaiCompatible: openaiCompatible,
      authBearer: authBearer,
    );
  }

  Uri get transcribeUri => Uri.parse('$sttBaseUrl$transcribePath');
  Uri get speechUri => Uri.parse('$ttsBaseUrl$speechPath');
}

/// Result of OpenAI-compatible STT, including optional confidence fields.
class TranscriptionResult {
  const TranscriptionResult({
    required this.text,
    this.language,
    this.languageProbability,
    this.avgLogprob,
    this.noSpeechProb,
    this.compressionRatio,
    this.durationSec,
  });

  final String text;
  final String? language;
  final double? languageProbability;
  final double? avgLogprob;
  final double? noSpeechProb;
  final double? compressionRatio;
  final double? durationSec;

  bool get isEmpty => text.trim().isEmpty;

  static TranscriptionResult fromJson(Map<dynamic, dynamic> map) {
    if (map['text'] == null) {
      throw StateError('STT response missing text field');
    }
    double? numField(List<String> keys) {
      for (final k in keys) {
        final v = map[k];
        if (v is num) return v.toDouble();
        if (v is String) {
          final parsed = double.tryParse(v.trim());
          if (parsed != null) return parsed;
        }
      }
      return null;
    }

    String? strField(List<String> keys) {
      for (final k in keys) {
        final v = map[k];
        if (v == null) continue;
        final s = v.toString().trim();
        if (s.isNotEmpty) return s;
      }
      return null;
    }

    return TranscriptionResult(
      text: map['text'].toString(),
      language: strField(const ['language']),
      languageProbability: numField(const [
        'language_probability',
        'languageProbability',
      ]),
      avgLogprob: numField(const ['avg_logprob', 'avgLogprob']),
      noSpeechProb: numField(const ['no_speech_prob', 'noSpeechProb']),
      compressionRatio: numField(const [
        'compression_ratio',
        'compressionRatio',
      ]),
      durationSec: numField(const ['duration', 'duration_sec', 'durationSec']),
    );
  }
}

/// HTTP client for AO-advertised OpenAI-compatible STT/TTS sidecars.
class SpeechClient {
  SpeechClient({
    required this.capabilities,
    this.headers = const {},
    this.speechToken,
    http.Client? httpClient,
  })  : _http = httpClient ?? http.Client(),
        _ownedClient = httpClient == null;

  final SpeechCapabilities capabilities;
  final Map<String, String> headers;
  final String? speechToken;
  final http.Client _http;
  final bool _ownedClient;

  Map<String, String> _authHeaders() {
    final out = <String, String>{};
    final token = speechToken?.trim();
    if (token != null && token.isNotEmpty) {
      out['Authorization'] = 'Bearer $token';
    } else if (capabilities.authBearer) {
      final existing = headers['Authorization'] ?? headers['authorization'];
      if (existing != null && existing.trim().isNotEmpty) {
        out['Authorization'] = existing.trim();
      }
    }
    return out;
  }

  /// Transcribe audio bytes; returns text only (back-compat).
  Future<String> transcribe(
    List<int> audioBytes, {
    String filename = 'audio.wav',
    String language = 'en',
  }) async {
    return (await transcribeDetailed(
      audioBytes,
      filename: filename,
      language: language,
    ))
        .text;
  }

  /// Transcribe with optional confidence / no-speech fields when the sidecar sends them.
  Future<TranscriptionResult> transcribeDetailed(
    List<int> audioBytes, {
    String filename = 'audio.wav',
    String language = 'en',
  }) async {
    final req = http.MultipartRequest('POST', capabilities.transcribeUri);
    req.headers.addAll(_authHeaders());
    req.fields['language'] = language;
    req.files.add(
      http.MultipartFile.fromBytes('file', audioBytes, filename: filename),
    );
    final streamed = await _http.send(req);
    final body = await streamed.stream.toBytes();
    if (streamed.statusCode < 200 || streamed.statusCode >= 300) {
      throw StateError(
        'STT failed HTTP ${streamed.statusCode}: ${utf8.decode(body, allowMalformed: true)}',
      );
    }
    final decoded = jsonDecode(utf8.decode(body));
    if (decoded is! Map) {
      throw StateError('STT response missing text field');
    }
    return TranscriptionResult.fromJson(decoded);
  }

  /// Synthesize [text] to WAV bytes.
  Future<List<int>> synthesize(String text, {String? voice}) async {
    final payload = <String, dynamic>{
      'text': text,
      'input': text,
      if (voice != null && voice.trim().isNotEmpty) 'voice': voice.trim(),
    };
    final resp = await _http.post(
      capabilities.speechUri,
      headers: {
        ..._authHeaders(),
        'Content-Type': 'application/json',
        'Accept': 'audio/wav',
      },
      body: jsonEncode(payload),
    );
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw StateError(
        'TTS failed HTTP ${resp.statusCode}: ${resp.body}',
      );
    }
    return resp.bodyBytes;
  }

  void close() {
    if (_ownedClient) {
      _http.close();
    }
  }
}
