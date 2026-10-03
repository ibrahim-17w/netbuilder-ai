// Applying a design is the promise the review makes when it ends with "ask
// me to rebuild with one of those". These tests hold that promise to three
// rules: a request is only honoured when it NAMES a design, applying one
// actually changes the plan, and applying the same design twice changes
// nothing the second time.
import 'package:flutter_test/flutter_test.dart';
import 'package:net_builder/models/network_intent.dart';
import 'package:net_builder/services/design_library.dart';
import 'package:net_builder/services/design_review.dart';

NetworkIntent _plan(String brief) => NetworkIntent.parseSimple('chat', brief);

bool _hasType(NetworkIntent plan, String type) =>
    plan.nodes.any((n) => n.type.trim().toLowerCase() == type);

void main() {
  group('naming a design', () {
    test('a design named by its catalog name resolves', () {
      expect(DesignApplier.namedIn('rebuild it with Redundant core'),
          DesignLibrary.byId('redundant-core'));
      expect(DesignApplier.namedIn('use the DMZ design'),
          DesignLibrary.byId('dmz'));
      expect(DesignApplier.namedIn('router on a stick please'),
          DesignLibrary.byId('router-on-a-stick'));
    });

    test('a design named by its id or shorthand resolves', () {
      expect(DesignApplier.namedIn('switch to branch-vpn')?.id, 'branch-vpn');
      expect(DesignApplier.namedIn('go flat lab')?.id, 'flat-lab');
      expect(DesignApplier.namedIn('put it behind a dmz')?.id, 'dmz');
      expect(DesignApplier.namedIn('add guest wireless')?.id, 'guest-wireless');
    });

    test('a request that names no design resolves to nothing', () {
      // "make it better" is the reviewer's job; it must never quietly pick
      // whichever design happens to sort first.
      expect(DesignApplier.namedIn('make it better'), isNull);
      expect(DesignApplier.namedIn('build it'), isNull);
      expect(DesignApplier.namedIn('why is the file so big?'), isNull);
    });

    test('a longer design name is not read as a shorter one', () {
      final d = DesignApplier.namedIn('servers on their own subnet');
      expect(d?.id, 'services-segmentation');
    });

    test('an unknown design name resolves to nothing rather than guessing', () {
      expect(DesignApplier.namedIn('rebuild with a three-tier mess'), isNull);
    });
  });

  group('applying a design', () {
    test('an unknown design id changes nothing', () {
      final plan = _plan('2 routers, 3 switches and 10 PCs');
      final r = DesignApplier.apply(plan, 'no-such-design');
      expect(r.plan.nodes, hasLength(plan.nodes.length));
      expect(r.added, isEmpty);
      expect(r.skipped, isEmpty);
      // Not even a stamp: nothing was applied, so nothing is claimed.
      expect(r.plan.notes.any((n) => n.startsWith('design:')), isFalse);
    });

    test('applying by name adds what the design asks for', () {
      final plan = _plan('1 router with 8 PCs');
      final r = DesignApplier.applyNamed(plan, 'rebuild it with a DMZ');
      expect(r, isNotNull);
      expect(_hasType(r!.plan, 'firewall'), isTrue);
      expect(r.added, isNotEmpty);
    });

    test('a device the plan already has is skipped, not duplicated', () {
      final plan = _plan('1 router with 8 PCs');
      expect(_hasType(plan, 'router'), isTrue);
      // The branch design wants a branch router; this plan already routes, so
      // adding a second router box would be a change nobody asked for.
      final r = DesignApplier.apply(plan, 'branch-vpn');
      expect(r.skipped.join(' '), contains('router'));
      expect(
        r.plan.nodes.where((n) => n.type.trim().toLowerCase() == 'router'),
        hasLength(1),
      );
    });

    test('a VLAN the plan already has is skipped', () {
      final plan = _plan('1 router, 2 switches, 20 PCs, VLAN 10 for users');
      expect(plan.vlans, contains(10));
      final r = DesignApplier.apply(plan, 'router-on-a-stick');
      expect(r.plan.vlans.where((id) => id == 10), hasLength(1));
      // The other VLANs the design wants are still added.
      expect(r.plan.vlans, contains(20));
    });

    test('the design is stamped so the plan says what it is', () {
      final plan = _plan('1 router with 8 PCs');
      final r = DesignApplier.apply(plan, 'dmz');
      expect(r.plan.notes, contains('design: dmz'));
    });

    test('names do not collide with the devices already in the plan', () {
      final plan = _plan('2 routers, 3 switches, 4 servers and 10 PCs');
      final r = DesignApplier.apply(plan, 'dmz');
      final names = [for (final n in r.plan.nodes) n.name.toUpperCase()];
      expect(names.toSet(), hasLength(names.length));
    });

    test('applying the same design twice is stable', () {
      final plan = _plan('1 router with 8 PCs');
      final once = DesignApplier.apply(plan, 'dmz');
      final twice = DesignApplier.apply(once.plan, 'dmz');
      expect(twice.added, isEmpty);
      expect(twice.plan.nodes, hasLength(once.plan.nodes.length));
      expect(twice.plan.vlans, once.plan.vlans);
      // One stamp, not two.
      expect(
        twice.plan.notes.where((n) => n == 'design: dmz'),
        hasLength(1),
      );
    });

    test('applying twice adds nothing the second time', () {
      final plan = _plan('1 router with 8 PCs');
      final once = DesignApplier.apply(plan, 'dmz');
      final twice = DesignApplier.apply(once.plan, 'dmz');
      expect(twice.added, isEmpty);
      expect(twice.skipped, isNotEmpty);
    });

    test('every design in the catalog can actually be applied', () {
      for (final d in DesignLibrary.all) {
        final r = DesignApplier.apply(_plan('1 router, 2 switches, 20 PCs'), d.id);
        expect(r.added, isNotEmpty, reason: '${d.id} applied to nothing');
        expect(r.plan.notes, contains('design: ${d.id}'));
      }
    });

    test('every design, applied, leaves a plan the reviewer accepts', () {
      // A design that makes the plan WORSE is worse than no design: applying
      // it would trade a working build for a broken one.
      for (final d in DesignLibrary.all) {
        final r = DesignApplier.apply(_plan('1 router, 2 switches, 20 PCs'), d.id);
        final review = DesignReviewer.review(r.plan);
        expect(review.findings.where((f) => f.severity == DesignSeverity.fault),
            isEmpty,
            reason: '${d.id} left a fault: ${review.headline}');
      }
    });
  });

  group('the whole loop', () {
    test('review -> suggest -> apply -> re-review closes', () {
      // The property the whole feature rests on: whenever the review offers
      // a design, asking for it by name and applying it makes the plan
      // better. Not "sometimes" and not "on one lucky brief".
      const briefs = <String>[
        '30 PCs and 3 switches with internet access',
        'a warehouse with 60 staff and a branch office',
        'a school with 400 students, 20 teachers and 10 servers',
        '2 routers, 3 switches, 4 servers and 10 PCs with OSPF area 0',
        'a clinic with 25 workstations and a file server',
        'a four-person office with one wireless router',
      ];
      var closed = 0;
      for (final brief in briefs) {
        final plan = _plan(brief);
        final first = DesignReviewer.review(plan);
        for (final offer in DesignLibrary.suggestionsForReview(plan, first)) {
          final asked = 'rebuild it with ${offer.design.name}';
          final applied = DesignApplier.applyNamed(plan, asked);
          expect(applied, isNotNull, reason: '"$asked" did not name a design');
          final second = DesignReviewer.review(applied!.plan);
          expect(second.score, greaterThan(first.score),
              reason: 'on "$brief", ${offer.design.id} took it from '
                  '${first.score} to ${second.score}');
          closed++;
        }
      }
      // A loop that never closes is not a loop. Real briefs have to produce
      // real designs, or the feature is decoration.
      expect(closed, greaterThan(0),
          reason: 'no brief in the list produced a design worth applying');
    });

    test('a design is never offered for a plan it cannot improve', () {
      const briefs = <String>[
        '1 router and 4 PCs',
        '1 router, 1 switch and 12 PCs on one network',
        '2 routers, 3 switches, 4 servers and 10 PCs with OSPF area 0',
      ];
      for (final brief in briefs) {
        final plan = _plan(brief);
        final first = DesignReviewer.review(plan);
        for (final offer in DesignLibrary.suggestionsForReview(plan, first)) {
          final applied = DesignApplier.apply(plan, offer.design.id);
          expect(DesignReviewer.review(applied.plan).score, greaterThan(first.score),
              reason: '${offer.design.id} was offered for "$brief" but '
                  'lowered the score');
        }
      }
    });

    test('every design the library offers can be asked for by name', () {
      // The review prints "ask me to rebuild with one of those". If any of
      // those names could not be typed back, the offer is a dead end.
      final plan = _plan(
          '2 routers, 3 switches, 4 servers, 60 PCs and a firewall');
      final offers = DesignLibrary.suggestionsForReview(
          plan, DesignReviewer.review(plan));
      for (final offer in offers) {
        final asked =
            'rebuild it with ${offer.design.name} for this site';
        expect(DesignApplier.namedIn(asked)?.id, offer.design.id,
            reason: '"$asked" did not resolve back to its own design');
      }
    });
  });
}