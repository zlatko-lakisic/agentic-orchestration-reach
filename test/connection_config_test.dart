import 'package:ao_reach/ao_reach.dart';
import 'package:test/test.dart';

void main() {
  test('appId is required and normalized', () {
    final cfg = ReachConnectionConfig(
      baseUrl: 'http://localhost:8765',
      headers: const {},
      appId: 'KnowBuddy',
    );
    expect(cfg.appId, 'knowbuddy');
  });

  test('empty appId is rejected', () {
    expect(
      () => ReachConnectionConfig(
        baseUrl: 'http://localhost:8765',
        headers: const {},
        appId: '  ',
      ),
      throwsA(isA<ArgumentError>()),
    );
  });

  test('invalid appId is rejected', () {
    expect(
      () => ReachConnectionConfig(
        baseUrl: 'http://localhost:8765',
        headers: const {},
        appId: 'Bad Id!',
      ),
      throwsA(isA<ArgumentError>()),
    );
  });
}
