import 'package:flutter_test/flutter_test.dart';
import 'package:net_builder/services/generation_control.dart';

void main() {
  test('a fresh token is current until it is cancelled', () {
    final control = GenerationControl();
    final token = control.begin();
    expect(control.isCurrent(token), isTrue);
    expect(control.cancelled, isFalse);

    control.cancel();
    expect(control.isCurrent(token), isFalse, reason: 'the turn was stopped');
    expect(control.cancelled, isTrue);
  });

  test('cancelling does not stop the next turn', () {
    final control = GenerationControl();
    final first = control.begin();
    control.cancel();
    expect(control.isCurrent(first), isFalse);

    final second = control.begin();
    expect(control.isCurrent(second), isTrue);
    expect(control.cancelled, isFalse);
    expect(control.isCurrent(first), isFalse,
        reason: 'a stale token must never look current again');
  });

  test('a second turn makes the first token stale without a cancel', () {
    final control = GenerationControl();
    final first = control.begin();
    final second = control.begin();
    expect(control.isCurrent(first), isFalse);
    expect(control.isCurrent(second), isTrue);
  });

  test('cancelling twice is harmless', () {
    final control = GenerationControl();
    final token = control.begin();
    control.cancel();
    final afterFirst = control.id;
    control.cancel();
    expect(control.isCurrent(token), isFalse);
    expect(control.id, greaterThan(afterFirst - 1));
  });

  group('a stop that already happened is visible at once', () {
    test('the future alone is not enough, so the probe is what the transports '
        'use', () async {
      final control = GenerationControl()..begin();
      control.cancel();

      // Built AFTER the cancel: the trigger is already complete, and a
      // completed future is only observable in a later microtask.
      final withoutProbe = AbortSignal(control.abortTrigger);
      expect(withoutProbe.isAborted, isFalse);
      await Future<void>.delayed(Duration.zero);
      expect(withoutProbe.isAborted, isTrue,
          reason: 'which is why a request built after the stop used to go out '
              'anyway');

      final withProbe = AbortSignal(
        control.abortTrigger,
        isAbortedNow: () => control.cancelled,
      );
      expect(withProbe.isAborted, isTrue,
          reason: 'read synchronously, the stop is honoured immediately');
      expect(
        () => withProbe.throwIfAborted(),
        throwsA(isA<AbortedException>()),
      );
    });

    test('a turn that was replaced counts as stopped', () {
      final control = GenerationControl();
      final first = control.begin();
      final second = control.begin();
      final signal = AbortSignal(
        control.abortTrigger,
        isAbortedNow: () => !control.isCurrent(first),
      );
      expect(signal.isAborted, isTrue);
      expect(
        AbortSignal(
          control.abortTrigger,
          isAbortedNow: () => !control.isCurrent(second),
        ).isAborted,
        isFalse,
        reason: 'the turn the user is waiting on is not stopped',
      );
    });

    test('a trigger that fails is not a cancellation', () async {
      final failing = Future<void>.error(Exception('the trigger broke'));
      final signal = AbortSignal(failing);
      await pumpEventQueue();
      expect(signal.isAborted, isFalse,
          reason: 'a broken signal must not be reported as the user stopping');
      expect(signal.isAbortError(Exception('a real failure')), isFalse);
    });
  });
}
