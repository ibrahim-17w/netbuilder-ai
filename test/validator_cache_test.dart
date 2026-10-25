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
// The one thing the cache used to deliberately miss: `NetworkIntent.revision`
// did not hash `serviceRules`, management addresses or IPv6 assignments, so
// an in-place edit touching only those was served stale. That gap is closed -
// the revision now hashes every input `validate` reads, through the
// sanitized key-sorted copy, so no credential ever enters the identifier -
// and the tests below pin both directions: a configuration-only edit is a
// cache miss with fresh findings, and a canvas-shaped edit (notes, layout)
// is NOT an edit at all.
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
    test(
      'the same findings for the 54-device plan, with and without a target',
      () {
        final plan = lab();
        expect(
          plan.nodes.length,
          greaterThanOrEqualTo(54),
          reason: 'the fixture must stay the 54-device lab',
        );

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
      },
    );

    test('the two targets get the answer each one deserves', () {
      final plan = lab();
      final pt = ValidatorService.validateCached(plan, target: 'packet-tracer');
      final gns3 = ValidatorService.validateCached(plan, target: 'gns3');

      expect(
        shape(pt),
        shape(ValidatorService.validate(plan, target: 'packet-tracer')),
      );
      expect(
        shape(gns3),
        shape(ValidatorService.validate(plan, target: 'gns3')),
      );
      expect(
        shape(pt),
        isNot(shape(gns3)),
        reason: '''
            The Packet Tracer target adds findings the gns3 target does not,
            so a cache keyed only on the plan would hand one target the other
            target's findings - which is exactly how "the plan has 54 devices
            and Packet Tracer refuses to run more than 50" stops being reported
            the moment anything asks about gns3 first.
          ''',
      );

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
      expect(
        findings,
        isNotEmpty,
        reason: '''
            An empty answer would make every comparison in this file vacuous -
            it would also be wrong: the 54-device lab is one device over the
            Packet Tracer device limit and several cables over a 2960's ports.
          ''',
      );
      expect(ValidatorService.hasErrors(findings), isTrue);
    });
  });

  group('the memo serves the plan it is holding', () {
    test('the same instance and target is answered from the cache', () {
      final plan = lab();

      final first = ValidatorService.validateCached(plan);
      final second = ValidatorService.validateCached(plan);

      expect(second.length, first.length);
      expect(
        shape(second),
        shape(first),
        reason: 'a second read must not drift from the first',
      );

      // A stampede guard: the cache hands out a COPY, so a caller appending to
      // what it was given cannot corrupt the entry for the next reader.
      expect(
        identical(first, second),
        isFalse,
        reason: 'validateCached must return a defensively copied list',
      );

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
      expect(
        reused,
        first.length,
        reason: 'every finding came back out of the memo',
      );
      expect(
        rebuilt,
        greaterThan(0),
        reason: '''
            The control pass rebuilt no findings, so the identity check above
            cannot tell a cache hit from a cache miss and this test proves
            nothing.
          ''',
      );
    });

    test(
      'a different instance of the same plan is not handed stale findings',
      () {
        final first = lab();
        final twin = lab();

        expect(
          identical(first, twin),
          isFalse,
          reason: 'the two plans are separate objects',
        );

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
        expect(
          reused,
          lessThan(held.length),
          reason: '''
            The memo answered for an object it was not asked about; identity is
            part of the key, so a different instance is always a miss.
          ''',
        );
        expect(cold.length, held.length);
      },
    );

    test(
      'a plan that changed content gets the findings of the new content',
      () {
        final good = lab();
        expect(
          shape(ValidatorService.validateCached(good)),
          shape(ValidatorService.validate(good)),
        );

        // A plan whose content is different in a way `revision` hashes: the
        // nodes, the links and the addressing all move.
        final changed = NetworkIntent.parseSimple(
          'perf',
          '2 routers, 4 switches and 8 pcs with OSPF',
        );
        expect(
          changed.revision,
          isNot(good.revision),
          reason: 'the fixture has to be a real edit, not the same plan',
        );

        final findings = ValidatorService.validateCached(changed);
        expect(shape(findings), shape(ValidatorService.validate(changed)));
        expect(
          findings.length,
          isNot(good.nodes.length),
          reason: '''
            The memo would have served the cached plan's findings for a plan
            that no longer exists.
          ''',
        );
      },
    );
  });

  group('the handed-back list cannot poison the memo', () {
    test('appending to it leaves the next read intact', () {
      final plan = lab();
      final original = ValidatorService.validateCached(plan);

      final poisoned = ValidatorService.validateCached(plan);
      poisoned.add(const ValidationIssue('error', 'poison'));
      expect(
        poisoned.length,
        original.length + 1,
        reason: 'the caller really did grow its own copy',
      );

      final next = ValidatorService.validateCached(plan);
      expect(
        shape(next),
        shape(original),
        reason: 'the memo was corrupted by the caller',
      );
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

  group('a configuration-only edit is a cache miss, not a stale answer', () {
    /// The same object edited in place - the shape a canvas-backed plan has:
    /// identity does not move, so only the revision can catch the edit.
    NetworkIntent editablePlan() {
      final plan = NetworkIntent.parseSimple(
        'cache',
        '1 router 1 switch 1 dns server and 2 pcs',
      );
      return plan;
    }

    test('editing only the DNS records moves the revision', () {
      final plan = editablePlan();
      final server = plan.nodes.firstWhere((n) => n.type == 'server');
      final before = plan.revision;
      // The parsed rules map is unmodifiable, so the edit rebuilds the
      // node - the same shape every in-place rule edit takes.
      plan.nodes[plan.nodes.indexOf(server)] = NetNode(
        name: server.name,
        type: server.type,
        model: server.model,
        services: server.services,
        serviceRules: {
          'dns': {
            'records': [
              {'name': 'web.lab', 'address': '192.168.1.53'},
            ],
          },
        },
      );
      expect(
        plan.revision,
        isNot(before),
        reason: 'the validator reads DNS records, so the revision must move',
      );
    });

    test(
      'editing a DHCP pool moves the revision, and credentials never enter it',
      () {
        final plan = editablePlan();
        final server = plan.nodes.firstWhere((n) => n.type == 'server');
        // NetNode fields are final, so a service change rebuilds the node -
        // the same thing the planner's follow-up paths do.
        NetNode rebuilt(Map<String, dynamic> rules) => NetNode(
          name: server.name,
          type: server.type,
          model: server.model,
          services: [...server.services, 'dhcp', 'aaa'],
          serviceRules: rules,
        );
        plan.nodes[plan.nodes.indexOf(server)] = rebuilt({
          'dhcp': {
            'pools': [
              {'poolName': 'staff', 'startIp': '192.168.1.10', 'maxUsers': 20},
            ],
          },
          'aaa': {
            'users': [
              {'username': 'admin', 'password': 'super-secret-9'},
            ],
          },
        });
        final withSecret = plan.revision;

        // The password VALUE changes in place: the sanitized copy the
        // revision hashes strips credential keys entirely, so the identifier
        // cannot distinguish the two - and no credential ever reaches a log,
        // a card or an export through it.
        final live = plan.nodes.firstWhere((n) => n.type == 'server');
        ((live.serviceRules['aaa']['users'] as List)[0] as Map)['password'] =
            'other-secret-7';
        expect(
          plan.revision,
          withSecret,
          reason: 'the password key is stripped before hashing',
        );

        // The non-credential part of the same rule still moves it.
        ((live.serviceRules['aaa']['users'] as List)[0] as Map)['username'] =
            'root';
        expect(plan.revision, isNot(withSecret));
      },
    );

    test('editing only an IPv6 assignment moves the revision', () {
      final plan = editablePlan();
      final router = plan.nodes.firstWhere((n) => n.type == 'router');
      final iface = plan.addressing
          .firstWhere((a) => a.node == router.name)
          .iface;
      plan.addressing.removeWhere((a) => a.node == router.name);
      plan.addressing.add(
        InterfaceAddr(node: router.name, iface: iface, ipCidr: '10.0.0.1/30'),
      );
      final before = plan.revision;
      plan.addressing[plan.addressing.indexWhere(
        (a) => a.node == router.name,
      )] = InterfaceAddr(
        node: router.name,
        iface: iface,
        ipCidr: '10.0.0.1/30',
        ip6Cidr: '2001:db8:1::1/64',
      );
      expect(plan.revision, isNot(before));
    });

    test('editing only the management address moves the revision', () {
      final plan = editablePlan();
      final router = plan.nodes.firstWhere((n) => n.type == 'router');
      final before = plan.revision;
      final edited = NetNode(
        name: router.name,
        type: router.type,
        model: router.model,
        mgmtIp: '10.0.0.9',
        services: router.services,
        serviceRules: router.serviceRules,
      );
      plan.nodes[plan.nodes.indexOf(router)] = edited;
      expect(plan.revision, isNot(before));
    });

    test('each of those edits refreshes the memoized validation', () {
      final plan = editablePlan();
      final server = plan.nodes.firstWhere((n) => n.type == 'server');
      final before = shape(ValidatorService.validateCached(plan));

      plan.nodes[plan.nodes.indexOf(server)] = NetNode(
        name: server.name,
        type: server.type,
        model: server.model,
        services: server.services,
        serviceRules: {
          'dns': {
            'records': [
              {'name': 'not-a-valid-record', 'address': 'nope'},
            ],
          },
        },
      );
      final after = shape(ValidatorService.validateCached(plan));
      // The edit introduced an invalid DNS record the validator flags; a
      // stale cache would have answered with the previous findings.
      expect(after, isNot(before), reason: 'the memo must miss on rules');
      expect(
        after.join('\n'),
        contains('invalid DNS record'),
        reason: 'the new findings reflect the edited rules, not the old',
      );
    });
  });

  group('a canvas-shaped edit is not an edit at all', () {
    test('changing only the notes keeps the revision', () {
      final plan = lab();
      final before = plan.revision;
      final moved = plan.copyWith(
        notes: [...plan.notes, 'layout: dragged PC7 to the side'],
      );
      expect(moved.revision, before);
    });

    test('a notes-only edit is still answered fresh and identically', () {
      final plan = lab();
      final first = shape(ValidatorService.validateCached(plan));
      final moved = plan.copyWith(notes: [...plan.notes, 'layout: moved']);
      expect(shape(ValidatorService.validateCached(moved)), first);
    });
  });
}
