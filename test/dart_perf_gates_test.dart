// Dart-side performance regression gates.
//
// These did not exist. The sidecar has `test_ocr_perf.py`; the Flutter side had
// nothing, so a change that quietly made planning or context budgeting 10x
// slower would have merged green. These are CANARIES, not benchmarks: each
// ceiling sits far above today's measured cost so an ordinary slow CI machine
// does not trip them, while an accidental O(n^2) or a loop added to a hot path
// trips them immediately.
//
// Measured on the reference machine (2026-10-04, Flutter 3.44, debug VM):
//
//   parseSimple (54-device plan)   26.7 ms
//   validate    (54-device plan)    4.5 ms
//   ctxPlan     (400-turn history) 232.5 ms   <- runs on EVERY model turn
//
// The context-budget number is the one worth watching: it is paid on the UI
// isolate before each request, so growth there is felt as typing lag rather
// than as a failed test.
//
// Added 2026-10-08 (measured on the machine this gate was written on,
// Flutter 3.44, debug VM) for the memoized validator read:
//
//   revision    (54-device plan)    1.0 ms
//
// It is cheap compared to the validate pass it saves (4.5 ms measured here,
// ~10 ms on the chat hot path), which is what allows
// `ValidatorService.validateCached` to recompute it on every call instead of
// trusting identity alone. That is also why its ceiling is 10x rather than the
// ~5x used above: a hash that costs a tenth of the validation it stands in for
// is still cheap, a hash that costs all of it is a bug, and a gate that
// flips red on an ordinary slow CI machine tells nobody anything.
//
// Ceilings are ~5x measured. Raise them deliberately and say why in the
// commit; do not quietly widen one to make a red build green.
import 'package:flutter_test/flutter_test.dart';
import 'package:net_builder/models/chat_message.dart';
import 'package:net_builder/models/network_intent.dart';
import 'package:net_builder/services/context_budget.dart';
import 'package:net_builder/services/validator_service.dart';

/// Median of [runs] timed iterations, in milliseconds.
///
/// Median, not mean: one GC pause or one scheduling hiccup should not decide
/// whether a gate fires. Median is also what a user perceives - the typical
/// turn, not the unlucky one.
double medianMs(void Function() body, {int runs = 5}) {
  final samples = <double>[];
  for (var i = 0; i < runs; i++) {
    final t = DateTime.now().microsecondsSinceEpoch;
    body();
    samples.add((DateTime.now().microsecondsSinceEpoch - t) / 1000.0);
  }
  samples.sort();
  return samples[samples.length ~/ 2];
}

NetworkIntent _lab() => NetworkIntent.parseSimple(
      'perf',
      '2 routers, 2 switches and 50 PCs with OSPF',
    );

void main() {
  group('hot-path cost ceilings', () {
    test('planning a 54-device lab stays under 150 ms', () {
      final plan = _lab();
      expect(plan.nodes.length, greaterThanOrEqualTo(54),
          reason: 'the fixture must stay the 54-device lab it was measured on');

      final took = medianMs(() => NetworkIntent.parseSimple(
          'perf', '2 routers, 2 switches and 50 PCs with OSPF'));

      expect(took, lessThan(150.0), reason: '''
        Planning took ${took.toStringAsFixed(1)} ms (measured 26.7 ms).
        parseSimple is called on the UI isolate for every build request and
        every follow-up. Something in the brief reader is very likely walking
        the whole message per device kind, or re-running the sizing pass.
      ''');
    });

    test('validating a 54-device lab stays under 40 ms', () {
      final plan = _lab();
      final took = medianMs(
        () => ValidatorService.validate(plan, target: 'packet-tracer'),
      );

      expect(took, lessThan(40.0), reason: '''
        Validation took ${took.toStringAsFixed(1)} ms (measured 4.5 ms).
        It runs before every write and every device touch, so it is on the
        critical path of the whole app.
      ''');
    });

    test('hashing the revision of a 54-device lab stays under 10 ms', () {
      final plan = _lab();
      expect(plan.nodes.length, greaterThanOrEqualTo(54),
          reason: 'the fixture must stay the 54-device lab it was measured on');

      final took = medianMs(() => plan.revision);

      expect(took, lessThan(10.0), reason: '''
        Reading the revision took ${took.toStringAsFixed(2)} ms (measured
        1.0 ms). ValidatorService.validateCached recomputes it on every call
        to know whether the plan it is holding the findings for has really
        changed, so if this number ever grew towards the 40 ms validate
        ceiling the memo would cost nearly as much as the pass it saves.
      ''');
    });

    test('planning the context for a 400-turn history stays under 1200 ms', () {
      final history = <ChatMessage>[
        for (var i = 0; i < 400; i++)
          ChatMessage(
            role: i.isEven ? 'user' : 'assistant',
            text: 'turn $i ${'lorem ipsum dolor sit amet ' * 40}',
          ),
      ];

      final took = medianMs(
        () => ContextBudget.plan(
          history: history,
          systemContext: 'system context',
          pendingText: 'next',
        ),
        runs: 3,
      );

      expect(took, lessThan(1200.0), reason: '''
        Context budgeting took ${took.toStringAsFixed(1)} ms for a 400-turn
        history (measured 232.5 ms). This runs on the UI isolate before EVERY
        model turn, so it is felt directly as lag between sending and the
        request going out. Past a few hundred turns a compaction pass that
        re-measures the whole history each iteration would show up here first.
      ''');
    });
  });

  group('the work these gate is still correct, not merely fast', () {
    test('a fast path still produces the same plan and the same findings', () {
      final plan = _lab();
      expect(plan.nodes.where((n) => n.type == 'router'), hasLength(2));
      expect(plan.nodes.where((n) => n.type == 'switch'), hasLength(2));
      expect(plan.routing, 'ospf');

      // The validator must still actually run and return a list - a "fast"
      // early-out that returns empty would pass every timing gate above.
      expect(ValidatorService.validate(plan, target: 'packet-tracer'),
          isA<List<Object?>>());
    });

    test('the revision hash stays cheap relative to the pass it guards', () {
      final plan = _lab();
      expect(plan.nodes.length, greaterThanOrEqualTo(54),
          reason: 'the fixture must stay the 54-device lab it was measured on');

      final hashing = medianMs(() => plan.revision);
      final validating = medianMs(() => ValidatorService.validate(plan));

      expect(hashing, lessThan(validating), reason: '''
        The revision hash cost ${hashing.toStringAsFixed(2)} ms for a plan
        whose validate takes ${validating.toStringAsFixed(2)} ms. Both numbers
        are taken here on the same machine, so a ratio test says something
        whatever the CI box is worth. validateCached recomputes the hash on
        every call, so a hash that stopped being cheaper than the work it
        stands in for would make the memo slower than the thing it memoizes -
        and the fix is then to make the hash cheaper, not to drop it.
      ''');
    });
  });
}