import 'dart:convert';

import 'package:ao_reach/ao_reach.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  group('SpeechCapabilities.tryParse', () {
    test('null when missing or disabled', () {
      expect(SpeechCapabilities.tryParse(null), isNull);
      expect(SpeechCapabilities.tryParse({'enabled': false}), isNull);
      expect(
        SpeechCapabilities.tryParse({'enabled': true, 'sttBaseUrl': 'http://x'}),
        isNull,
      );
    });

    test('parses advertise urls and bearer flag', () {
      final caps = SpeechCapabilities.tryParse({
        'enabled': true,
        'openaiCompatible': true,
        'sttBaseUrl': 'http://10.0.0.5:8090/',
        'ttsBaseUrl': 'http://10.0.0.5:8091/',
        'auth': 'bearer',
      });
      expect(caps, isNotNull);
      expect(caps!.sttBaseUrl, 'http://10.0.0.5:8090');
      expect(caps.ttsBaseUrl, 'http://10.0.0.5:8091');
      expect(caps.authBearer, isTrue);
      expect(caps.transcribeUri.toString(), 'http://10.0.0.5:8090/v1/audio/transcriptions');
      expect(caps.speechUri.toString(), 'http://10.0.0.5:8091/v1/audio/speech');
    });
  });

  group('SpeechCapabilities.withOverrides', () {
    const base = SpeechCapabilities(
      sttBaseUrl: 'http://10.0.0.5:8090',
      ttsBaseUrl: 'http://10.0.0.5:8091',
      authBearer: true,
    );

    test('null and empty leave advertised urls', () {
      final a = base.withOverrides();
      expect(a.sttBaseUrl, base.sttBaseUrl);
      expect(a.ttsBaseUrl, base.ttsBaseUrl);
      expect(identical(a, base), isTrue);

      final b = base.withOverrides(sttBaseUrl: '  ', ttsBaseUrl: '');
      expect(b.sttBaseUrl, base.sttBaseUrl);
      expect(b.ttsBaseUrl, base.ttsBaseUrl);
    });

    test('replaces non-empty overrides and strips trailing slash', () {
      final caps = base.withOverrides(
        sttBaseUrl: 'http://10.0.0.5:8093/',
        ttsBaseUrl: 'http://10.0.0.5:8092',
      );
      expect(caps.sttBaseUrl, 'http://10.0.0.5:8093');
      expect(caps.ttsBaseUrl, 'http://10.0.0.5:8092');
      expect(caps.authBearer, isTrue);
      expect(caps.transcribePath, '/v1/audio/transcriptions');
    });
  });

  group('SpeechClient', () {
    test('transcribe posts multipart and returns text', () async {
      final mock = MockClient((request) async {
        expect(request.method, 'POST');
        expect(request.url.path, '/v1/audio/transcriptions');
        expect(request.headers['authorization'], 'Bearer secret');
        expect(request.headers['content-type'], contains('multipart/form-data'));
        return http.Response(jsonEncode({'text': 'hello world'}), 200);
      });
      final client = SpeechClient(
        capabilities: const SpeechCapabilities(
          sttBaseUrl: 'http://speech.test:8090',
          ttsBaseUrl: 'http://speech.test:8091',
          authBearer: true,
        ),
        speechToken: 'secret',
        httpClient: mock,
      );
      final text = await client.transcribe([1, 2, 3], filename: 'u.wav');
      expect(text, 'hello world');
      client.close();
    });

    test('transcribeDetailed with text-only body', () async {
      final mock = MockClient((request) async {
        expect(request.url.host, 'speech.test');
        expect(request.url.port, 8090);
        return http.Response(jsonEncode({'text': 'hi'}), 200);
      });
      final client = SpeechClient(
        capabilities: const SpeechCapabilities(
          sttBaseUrl: 'http://speech.test:8090',
          ttsBaseUrl: 'http://speech.test:8091',
        ),
        httpClient: mock,
      );
      final result = await client.transcribeDetailed([1, 2, 3]);
      expect(result.text, 'hi');
      expect(result.avgLogprob, isNull);
      expect(result.noSpeechProb, isNull);
      expect(result.isEmpty, isFalse);
      client.close();
    });

    test('transcribeDetailed populates confidence fields', () async {
      final mock = MockClient((request) async {
        return http.Response(
          jsonEncode({
            'text': 'prompt',
            'language': 'en',
            'language_probability': 0.98,
            'avg_logprob': -0.25,
            'no_speech_prob': 0.01,
            'compression_ratio': 1.4,
            'duration': 1.25,
          }),
          200,
        );
      });
      final client = SpeechClient(
        capabilities: const SpeechCapabilities(
          sttBaseUrl: 'http://speech.test:8090',
          ttsBaseUrl: 'http://speech.test:8091',
        ),
        httpClient: mock,
      );
      final result = await client.transcribeDetailed([9]);
      expect(result.text, 'prompt');
      expect(result.language, 'en');
      expect(result.languageProbability, closeTo(0.98, 1e-9));
      expect(result.avgLogprob, closeTo(-0.25, 1e-9));
      expect(result.noSpeechProb, closeTo(0.01, 1e-9));
      expect(result.compressionRatio, closeTo(1.4, 1e-9));
      expect(result.durationSec, closeTo(1.25, 1e-9));
      client.close();
    });

    test('override STT host is used for multipart POST', () async {
      final mock = MockClient((request) async {
        expect(request.url.host, 'override.test');
        expect(request.url.port, 8093);
        return http.Response(jsonEncode({'text': 'ok'}), 200);
      });
      final caps = const SpeechCapabilities(
        sttBaseUrl: 'http://speech.test:8090',
        ttsBaseUrl: 'http://speech.test:8091',
      ).withOverrides(sttBaseUrl: 'http://override.test:8093');
      final client = SpeechClient(capabilities: caps, httpClient: mock);
      expect(await client.transcribe([0]), 'ok');
      client.close();
    });

    test('synthesize posts json and returns wav bytes', () async {
      final mock = MockClient((request) async {
        expect(request.method, 'POST');
        expect(request.url.path, '/v1/audio/speech');
        final body = jsonDecode(request.body) as Map;
        expect(body['text'], 'hi');
        return http.Response.bytes([0x52, 0x49, 0x46, 0x46], 200, headers: {
          'content-type': 'audio/wav',
        });
      });
      final client = SpeechClient(
        capabilities: const SpeechCapabilities(
          sttBaseUrl: 'http://speech.test:8090',
          ttsBaseUrl: 'http://speech.test:8091',
        ),
        httpClient: mock,
      );
      final wav = await client.synthesize('hi');
      expect(wav, [0x52, 0x49, 0x46, 0x46]);
      client.close();
    });
  });
}
