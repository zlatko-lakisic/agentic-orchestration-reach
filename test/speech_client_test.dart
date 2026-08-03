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
