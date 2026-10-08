// The memoized read of the validator, and the ways it could lie.
//
// `ValidatorService.validate` is the single source of truth: it is a pure
// function of the plan and the target, it walks every node, every address,
// every link and every service rule, and the chat screen asks it again on
// every rebuild of the activity list. `validateCached` answers the same
// question from a one-entry cache, which means every way the cache could
// answer a DIFFERENT question than `validate` would is a bug that shows up as
// a build card saying "fix the plan first" for a plan with nothing to fix (or
// the reverse, which is worse).
//
// The cache is therefore pinned here on three axes: it must agree with
// `validate` finding for finding, it must answer for the plan it is HOLDING
// (identity, and the revision hash, because a plan is edited in place), and it
// must answer for the target it was asked for. A caller that mutates the list
// it handed must not be able to poison the next read.
//
// The one thing the cache deliberately does NOT do: `NetworkIntent.revision`
// does not hash `serviceRules`, `users` or `security.records`, so an in-place
// edit that touches only those and nothing else can be served stale. That is
// the documented trade of the double key - identity catches a different
// object, revision catches a real edit - and the fix for that gap is a cheaper
// complete hash, not a caller that guesses when the cache is valid. Anything
// that has just edited a plan in place should call `validate` directly.
import 'package:flutter_test/flutter_test.dart';
import 'package:net_builder/models/network_intent.dart';
import 'package:net_builder/services/validator_service.dart';

/// The fixture the perf gates measure on, so the memo is pinned on the plan
/// whose cost it actually exists to save.
NetworkIntent lab() => NetworkIntent.parseSimple(
      'perf',
      '2 routers, 2 switches and 50 PCs with OSPF',
    );

/// Findings as comparable text, so two lists can be compared for CONTENT.
///
/// `ValidationIssue` deliberately has no value equality - it is a message
/// object, not a value object - so the lists are compared by what they say.
List<String> shape(List<ValidationIssue> issues) => [
      for (final i in issues) '${i.severity}|${i.blocking}|${i.message}',
    ];

void main() {
  // The memo is one static entry shared by every test in this file, so each
  // test starts from an empty one: a suite that ran (a) first would otherwise
  // "prove" (c) by handing (c) the answer it already had.
  setUp(ValidatorService.clearCacheForTest);

  group('the memo answers what validate answers', () {
    test('the same findings for the 54-device plan, with and without a target',
        () {
      final plan = lab();
      expect(plan.nodes.length, greaterThanOrEqualTo(54),
          reason: 'the fixture must stay the 54-device lab');

      expect(
        shape(ValidatorService.validateCached(plan)),
        shape(ValidatorService.validate(plan)),
        reason: 'validateCached with no target must match validate',
      );
      expect(
        shape(ValidatorService.validateCached(plan, target: 'packet-tracer')),
        shape(ValidatorService.validate(plan, target: 'packet-tracer')),
        reason: 'validateCached with a target must match validate',
      );
    });

    test('the two targets get the answer each one deserves', () {
      final plan = lab();
      final pt = ValidatorService.validateCached(plan, target: 'packet-tracer');
      final gns3 = ValidatorService.validateCached(plan, target: 'gns3');

      expect(shape(pt), shape(ValidatorService.validate(plan,
          target: 'packet-tracer')));
      expect(shape(gns3), shape(ValidatorService.validate(plan,
          target: 'gns3')));
      expect(shape(pt), isNot(shape(gns3)),
          reason: '''
            The Packet Tracer target adds findings the gns3 target does not,
            so a cache keyed only on the plan would hand one target the other
            target's findings - which is exactly how "the plan has 54 devices
            and Packet Tracer refuses to run more than 50" stops being reported
            the moment anything asks about gns3 first.
          ''');

      // The entry holds ONE plan: asking for packet-tracer again after the
      // gns3 pass must still produce packet-tracer's findings.
      expect(
        shape(ValidatorService.validateCached(plan, target: 'packet-tracer')),
        shape(pt),
      );
    });

    test('findings are actually present, so agreement means agreement', () {
      final plan = lab();
      final findings = ValidatorService.validateCached(plan);
      expect(findings, isNotEmpty,
          reason: '''
            An empty answer would make every comparison in this file vacuous -
            it would also be wrong: the 54-device lab is one device over the
            Packet Tracer device limit and several cables over a 2960's ports.
          ''');
      expect(ValidatorService.hasErrors(findings), isTrue);
    });
  });

  group('the memo serves the plan it is holding', () {
    test('the same instance and target is answered from the cache', () {
      final plan = lab();

      final first = ValidatorService.validateCached(plan);
      final second = ValidatorService.validateCached(plan);

      expect(second.length, first.length);
      expect(shape(second), shape(first),
          reason: 'a second read must not drift from the first');

      // A stampede guard: the cache hands out a COPY, so a caller appending to
      // what it was given cannot corrupt the entry for the next reader.
      expect(identical(first, second), isFalse,
          reason: 'validateCached must return a defensively copied list');

      // Proof it was the memo and not a second pass: `validate` allocates new
      // finding objects every call, so if these came back as the SAME objects
      // something held on to them. The control below shows this fixture really
      // does contain findings a re-pass would rebuild.
      final cold = ValidatorService.validate(plan);
      var reused = 0;
      var rebuilt = 0;
      for (var i = 0; i < first.length; i++) {
        if (identical(first[i], second[i])) reused++;
        if (!identical(first[i], cold[i])) rebuilt++;
      }
      expect(reused, first.length,
          reason: 'every finding came back out of the memo');
      expect(rebuilt, greaterThan(0),
          reason: '''
            The control pass rebuilt no findings, so the identity check above
            cannot tell a cache hit from a cache miss and this test proves
            nothing.
          ''');
    });

    test('a different instance of the same plan is not handed stale findings',
        () {
      final first = lab();
      final twin = lab();

      expect(identical(first, twin), isFalse,
          reason: 'the two plans are separate objects');

      final held = ValidatorService.validateCached(first);
      // A second parse of the same brief produces the same network. The memo
      // must still answer for the object it was HANDED, not for the twin it
      // happened to be holding.
      final twinFindings = ValidatorService.validateCached(twin);

      expect(shape(twinFindings), shape(ValidatorService.validate(twin)));
      expect(shape(held), shape(ValidatorService.validate(first)));

      // Same content, different object: the answer is the same content, and it
      // was produced by a fresh pass rather than by the twin's entry.
      final cold = ValidatorService.validate(first);
      var reused = 0;
      for (var i = 0; i < held.length; i++) {
        if (identical(held[i], twinFindings[i])) reused++;
      }
      expect(reused, lessThan(held.length),
          reason: '''
            The memo answered for an object it was not asked about; identity is
            part of the key, so a different instance is always a miss.
          ''');
      expect(cold.length, held.length);
    });

    test('a plan that changed content gets the findings of the new content',
        () {
      final good = lab();
      expect(shape(ValidatorService.validateCached(good)),
          shape(ValidatorService.validate(good)));

      // A plan whose content is different in a way `revision` hashes: the
      // nodes, the links and the addressing all move.
      final changed = NetworkIntent.parseSimple(
        'perf',
        '2 routers, 4 switches and 8 pcs with OSPF',
      );
      expect(changed.revision, isNot(good.revision),
          reason: 'the fixture has to be a real edit, not the same plan');

      final findings = ValidatorService.validateCached(changed);
      expect(shape(findings), shape(ValidatorService.validate(changed)));
      expect(findings.length, isNot(good.nodes.length),
          reason: '''
            The memo would have served the cached plan's findings for a plan
            that no longer exists.
          ''');
    });
  });

  group('the handed-back list cannot poison the memo', () {
    test('appending to it leaves the next read intact', () {
      final plan = lab();
      final original = ValidatorService.validateCached(plan);

      final poisoned = ValidatorService.validateCached(plan);
      poisoned.add(const ValidationIssue('error', 'poison'));
      expect(poisoned.length, original.length + 1,
          reason: 'the caller really did grow its own copy');

      final next = ValidatorService.validateCached(plan);
      expect(shape(next), shape(original),
          reason: 'the memo was corrupted by the caller');
    });

    test('clearing it leaves the next read intact', () {
      final plan = lab();
      final original = ValidatorService.validateCached(plan);
      expect(original, isNotEmpty);

      final poisoned = ValidatorService.validateCached(plan);
      poisoned.clear();
      expect(poisoned, isEmpty);

      expect(shape(ValidatorService.validateCached(plan)), shape(original));
    });
  });
}
