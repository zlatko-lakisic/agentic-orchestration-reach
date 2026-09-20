import 'dart:async';

import 'package:ao_reach/ao_reach.dart';
import 'package:test/test.dart';

void main() {
  group('awaitCompleterWithIdleTimeout', () {
    test('completes when future completes within idle window', () async {
      final done = Completer<String>();
      var progress = DateTime.now();
      final future = awaitCompleterWithIdleTimeout(
        done,
        idleTimeout: const Duration(seconds: 2),
        absoluteTimeout: const Duration(seconds: 10),
        lastProgressAt: () => progress,
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      done.complete('ok');
      expect(await future, 'ok');
    });

    test('idle timeout when no progress', () async {
      final done = Completer<String>();
      final start = DateTime.now();
      await expectLater(
        awaitCompleterWithIdleTimeout(
          done,
          idleTimeout: const Duration(milliseconds: 80),
          absoluteTimeout: const Duration(seconds: 5),
          lastProgressAt: () => start,
        ),
        throwsA(isA<TimeoutException>()),
      );
    });

    test('progress resets idle clock', () async {
      final done = Completer<String>();
      var progress = DateTime.now();
      final ticker = Timer.periodic(const Duration(milliseconds: 40), (_) {
        progress = DateTime.now();
      });
      try {
        final future = awaitCompleterWithIdleTimeout(
          done,
          idleTimeout: const Duration(milliseconds: 120),
          absoluteTimeout: const Duration(seconds: 5),
          lastProgressAt: () => progress,
        );
        await Future<void>.delayed(const Duration(milliseconds: 280));
        done.complete('alive');
        expect(await future, 'alive');
      } finally {
        ticker.cancel();
      }
    });

    test('absolute timeout wins even with fresh progress', () async {
      final done = Completer<String>();
      var progress = DateTime.now();
      final ticker = Timer.periodic(const Duration(milliseconds: 25), (_) {
        progress = DateTime.now();
      });
      try {
        await expectLater(
          awaitCompleterWithIdleTimeout(
            done,
            idleTimeout: const Duration(seconds: 5),
            absoluteTimeout: const Duration(milliseconds: 150),
            lastProgressAt: () => progress,
          ),
          throwsA(isA<TimeoutException>()),
        );
      } finally {
        ticker.cancel();
      }
    });
  });
}
