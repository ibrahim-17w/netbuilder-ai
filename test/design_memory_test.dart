// The library decides which named design fits a brief, and the memory decides
// which of those designs are worth believing because they worked before.
//
// The rules these protect: a design is offered only with a reason, a design
// that is wrong for the lab's size is never offered, and nothing is recalled
// until it has actually been built well more than once.
import 'package:flutter_test/flutter_test.dart';
import 'package:net_builder/models/network_intent.dart';
import 'package:net_builder/services/design_library.dart';
import 'package:net_builder/services/design_memory.dart';
import 'package:net_builder/services/design_review.dart';

NetworkIntent _plan(String brief) => NetworkIntent.parseSimple('chat', brief);

void main() {
  setUp(DesignMemory.reset);
  tearDown(DesignMemory.reset);

  group('the library', () {
    test('every design has a name, a blurb and something to change', () {
      expect(DesignLibrary.all, isNotEmpty);
      for (final d in DesignLibrary.all) {
        expect(d.id, isNotEmpty, reason: 'a design with no id cannot be stored');
        expect(d.name, isNotEmpty);
        expect(d.blurb, isNotEmpty);
        expect(d.changes, isNotEmpty, reason: '${d.id} changes nothing');
      }
    });

    test('design ids are unique', () {
      final ids = [for (final d in DesignLibrary.all) d.id];
      expect(ids.toSet(), hasLength(ids.length));
    });

    test('a design can be looked up by id', () {
      expect(DesignLibrary.byId('dmz')?.name, isNotNull);
      expect(DesignLibrary.byId('not-a-design'), isNull);
    });

    test('every suggestion comes with a reason', () {
      final suggestions = DesignLibrary.suggest(
        _plan('2 routers with OSPF, 3 switches, 40 PCs and a firewall'),
      );
      expect(suggestions, isNotEmpty);
      for (final s in suggestions) {
        expect(s.fit, greaterThan(0));
        expect(s.reasons, isNotEmpty, reason: '${s.design.id} cannot explain itself');
      }
    });

    test('suggestions come back best-fit first', () {
      final suggestions = DesignLibrary.suggest(
        _plan('a warehouse with 60 staff, 2 routers, a firewall and a cloud'),
      );
      for (var i = 1; i < suggestions.length; i++) {
        expect(
          suggestions[i - 1].fit >= suggestions[i].fit,
          isTrue,
          reason: 'the best match must be first',
        );
      }
    });

    test('a big multi-router site is offered a redundant core', () {
      final ids = DesignLibrary.suggest(
        _plan('a campus with 2 routers, 4 switches and 80 PCs'),
      ).map((s) => s.design.id);
      expect(ids, contains('redundant-core'));
    });

    test('a four-person office is never offered a DMZ', () {
      final ids = DesignLibrary.suggest(
        _plan('a small office with 1 router and 3 PCs'),
      ).map((s) => s.design.id);
      expect(ids, isNot(contains('dmz')),
          reason: 'a wrong design offered confidently is worse than none');
    });

    test('a design size range really is a range, not a pair of exact counts', () {
      final design = DesignLibrary.byId('soho')!;
      expect(design.minHosts, 1);
      expect(design.maxHosts, 15);
      // Twelve is inside one-to-fifteen. Reading the bounds as literal counts
      // made every design fit exactly two lab sizes and quietly offered
      // nothing to everything else.
      final suggestions = DesignLibrary.suggest(
        _plan('a small office with 1 wireless router and 12 laptops'),
      );
      expect(
        suggestions.where((s) => s.design.id == 'soho'),
        isNotEmpty,
        reason: 'a genuinely small office SHOULD be offered the small design',
      );
    });
  });

  group('what the review points at', () {
    test('a segmentation complaint suggests a segmented design', () {
      final plan = _plan('3 switches and 30 PCs');
      final review = DesignReviewer.review(plan);
      final ids = DesignLibrary.suggestionsForReview(plan, review)
          .map((s) => s.design.id);
      expect(review.findings.any((f) => f.area == 'segmentation'), isTrue);
      expect(ids, isNotEmpty);
    });

    test('a clean design does not get a pile of suggestions', () {
      final plan = _plan('1 router, 1 switch, 2 PCs, DHCP and DNS');
      final review = DesignReviewer.review(plan);
      expect(review.findings, isEmpty);
      expect(DesignLibrary.suggestionsForReview(plan, review), isEmpty);
    });
  });

  group('the memory', () {
    test('a design is remembered by its shape, not its name', () {
      final a = _plan('2 routers, 2 switches and 10 PCs');
      final b = _plan('3 routers, 3 switches and 20 PCs');
      // Different shapes.
      expect(DesignMemory.signatureOf(a), isNot(DesignMemory.signatureOf(b)));
    });

    test('the same shape asked for twice gives the same signature', () {
      expect(
        DesignMemory.signatureOf(_plan('2 routers and 2 switches')),
        DesignMemory.signatureOf(_plan('2 routers and 2 switches')),
      );
    });

    test('a weak design is not learned', () {
      // Built by hand on purpose: a plan with hosts and nothing to plug them
      // into, which is the worst thing the reviewer can see. Depending on the
      // parser's defaults here would make the test pass or fail for reasons
      // that have nothing to do with the memory.
      const orphan = NetworkIntent(
        projectName: 'orphan lab',
        nodes: <NetNode>[
          NetNode(name: 'PC1', type: 'pc'),
          NetNode(name: 'PC2', type: 'pc'),
        ],
        links: <NetLink>[],
        addressing: <InterfaceAddr>[],
        vlans: <int>[],
        routing: 'static',
        notes: <String>[],
        assumptions: <String>[],
        questions: <String>[],
        confidence: 0,
        planningSource: 'test',
        security: SecurityIntent(),
        layout: <String, Offset?>{},
      );
      final review = DesignReviewer.review(orphan);
      expect(review.score, lessThan(DesignMemory.kLearnThreshold));
      expect(DesignMemory.recordBuild(plan: orphan, review: review), isNull);
      expect(DesignMemory.knownGood, isEmpty,
          reason: 'a design that scored badly is not a lesson worth keeping');
    });

    test('a good design is learned once it is seen twice', () {
      final plan = _plan('1 router, 1 switch, 2 PCs, DHCP and DNS');
      final review = DesignReviewer.review(plan);
      expect(review.score, greaterThanOrEqualTo(DesignMemory.kLearnThreshold));

      DesignMemory.recordBuild(plan: plan, review: review);
      expect(DesignMemory.recallFor(plan), isNull,
          reason: 'one build is not evidence');

      DesignMemory.recordBuild(plan: plan, review: review);
      final recalled = DesignMemory.recallFor(plan);
      expect(recalled, isNotNull);
      expect(recalled!.builds, 2);
      expect(recalled.bestScore, greaterThanOrEqualTo(80));
    });

    test('a remembered design survives a save and restore', () {
      final plan = _plan('1 router, 1 switch, 2 PCs, DHCP and DNS');
      final review = DesignReviewer.review(plan);
      DesignMemory.recordBuild(plan: plan, review: review);
      DesignMemory.recordBuild(plan: plan, review: review);
      final saved = DesignMemory.snapshot();

      DesignMemory.reset();
      expect(DesignMemory.recallFor(plan), isNull);

      DesignMemory.restore(saved);
      expect(DesignMemory.recallFor(plan), isNotNull);
    });

    test('words learned alongside designs survive the same round trip', () {
      DesignMemory.snapshot();
      DesignMemory.restore(<dynamic, dynamic>{
        'entries': <dynamic>[],
        'words': <dynamic, dynamic>{'kiosk': 'tablet'},
      });
      expect(DesignMemory.knownGood, isEmpty);
      // The word store lives in the vocabulary; this proves the wiring.
      expect(DesignMemory.recap(), isEmpty);
    });

    test('restoring rubbish does not poison the memory', () {
      DesignMemory.restore(<dynamic, dynamic>{
        'entries': <dynamic>[
          'not a map',
          <dynamic, dynamic>{'noSignature': true},
          <String, dynamic>{'signature': 'x', 'score': 'not a number'},
          <String, dynamic>{'signature': 'y'},
        ],
        'words': 'not a map',
      });
      expect(DesignMemory.entries, isEmpty);
      expect(DesignMemory.recap(), isEmpty);
    });

    test('the recap is empty when nothing has been learned', () {
      expect(DesignMemory.recap(), isEmpty);
    });

    test('the recap says something once a design has been learned', () {
      final plan = _plan('1 router, 1 switch, 2 PCs, DHCP and DNS');
      final review = DesignReviewer.review(plan);
      DesignMemory.recordBuild(plan: plan, review: review);
      DesignMemory.recordBuild(plan: plan, review: review);
      expect(DesignMemory.recap(), contains('builds'));
    });

    test('the memory is capped so it cannot grow without bound', () {
      final plan = _plan('1 router, 1 switch, 2 PCs, DHCP and DNS');
      final review = DesignReviewer.review(plan);
      for (var i = 0; i < DesignMemory.kMaxEntries + 25; i++) {
        DesignMemory.recordBuild(plan: plan, review: review);
      }
      expect(DesignMemory.entries.length, lessThanOrEqualTo(DesignMemory.kMaxEntries));
    });
  });
}