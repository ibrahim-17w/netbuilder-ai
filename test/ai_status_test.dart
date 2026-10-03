import 'package:flutter_test/flutter_test.dart';

import 'package:net_builder/services/ai_provider.dart';

/// What the app says about the model backend has to be TRUE and said ONCE:
/// the header sign carries the live state, the turn's source line carries
/// provenance. These pin the words, because the old contract (a disclaimer
/// repeated inside every offline answer) is exactly what must not come back.
void main() {
  group('AiStatus.describe reads only the facts it is given', () {
    test('private mode wins over everything, even a key and a failure', () {
      final status = AiStatus.describe(
        providerLabel: 'Google Gemini',
        model: 'gemini-2.5-flash',
        hasKey: true,
        privateMode: true,
        lastError: 'HTTP 503: {}',
      );
      expect(status.availability, AiAvailability.private);
      expect(status.short, 'AI: private mode');
      expect(status.source, contains('private mode'));
      expect(status.detail, contains('no model is called'));
    });

    test('no key means the built-in planner answers', () {
      final status = AiStatus.describe(
        providerLabel: 'Google Gemini',
        model: 'gemini-2.5-flash',
        hasKey: false,
        privateMode: false,
      );
      expect(status.availability, AiAvailability.keyless);
      expect(status.short, 'AI: off — no key');
      expect(status.source, contains('built-in planner'));
      expect(status.source, contains('no API key'));
    });

    test('a key plus a failure is reported, not hidden', () {
      final status = AiStatus.describe(
        providerLabel: 'OpenAI-compatible',
        model: 'llama-3.3-70b-versatile',
        hasKey: true,
        privateMode: false,
        lastError: 'HTTP 503: {}',
      );
      expect(status.availability, AiAvailability.failing);
      expect(status.short, 'AI: not answering');
      expect(status.source, contains('the API model did not answer'));
      expect(status.detail, 'HTTP 503: {}');
    });

    test('a key and no error is ready, naming the provider', () {
      final status = AiStatus.describe(
        providerLabel: 'OpenAI-compatible',
        model: 'llama-3.3-70b-versatile',
        hasKey: true,
        privateMode: false,
      );
      expect(status.availability, AiAvailability.ready);
      expect(status.short, 'AI: OpenAI-compatible');
      expect(status.source, 'via OpenAI-compatible (llama-3.3-70b-versatile)');
      expect(status.detail, isEmpty);
    });

    test('a cleared failure is not remembered as one', () {
      // The header sign must go quiet the moment a later call works, so an
      // empty lastError with a key is READY, never the stale red state.
      final status = AiStatus.describe(
        providerLabel: 'Google Gemini',
        model: 'gemini-2.5-flash',
        hasKey: true,
        privateMode: false,
        lastError: '',
      );
      expect(status.availability, AiAvailability.ready);
      expect(status.short, isNot(contains('not answering')));
    });
  });

  group('the source line is provenance, not a disclaimer', () {
    test('the planner says no model was called', () {
      // Build/edit/redraw turns run the local engine; they must never be
      // mistaken for model words.
      expect(AiStatus.plannerSource, contains('built-in planner'));
      expect(AiStatus.plannerSource, contains('no model was called'));
    });

    test('ready and failing name different backends', () {
      final ready = AiStatus.describe(
        providerLabel: 'Google Gemini',
        model: 'gemini-2.5-flash',
        hasKey: true,
        privateMode: false,
      );
      final failing = AiStatus.describe(
        providerLabel: 'Google Gemini',
        model: 'gemini-2.5-flash',
        hasKey: true,
        privateMode: false,
        lastError: 'HTTP 429',
      );
      expect(ready.source, isNot(failing.source));
      expect(ready.source, contains('via'));
      expect(failing.source, contains('built-in planner'));
    });

    test('the API model is in play exactly when a key and no private mode', () {
      final ready = AiStatus.describe(
        providerLabel: 'Google Gemini',
        model: 'm',
        hasKey: true,
        privateMode: false,
      );
      final failing = AiStatus.describe(
        providerLabel: 'Google Gemini',
        model: 'm',
        hasKey: true,
        privateMode: false,
        lastError: 'x',
      );
      expect(ready.apiInUse, isTrue);
      expect(failing.apiInUse, isTrue);
      expect(
        AiStatus.describe(
          providerLabel: 'Google Gemini',
          model: 'm',
          hasKey: false,
          privateMode: false,
        ).apiInUse,
        isFalse,
      );
      expect(
        AiStatus.describe(
          providerLabel: 'Google Gemini',
          model: 'm',
          hasKey: true,
          privateMode: true,
        ).apiInUse,
        isFalse,
      );
    });
  });
}
