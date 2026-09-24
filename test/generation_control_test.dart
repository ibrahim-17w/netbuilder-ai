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
}
