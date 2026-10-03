// The words people actually use must reach the plan. "15 staff", "a website",
// "a branch office" are how a brief is really written, and before the domain
// vocabulary those words named nothing - the devices they described were
// dropped on the floor.
//
// The rule these tests protect: the vocabulary is ADDITIVE. A brief written in
// network terms must resolve exactly as it always did, or the app has traded
// one kind of wrong for another.
import 'package:flutter_test/flutter_test.dart';
import 'package:net_builder/models/network_intent.dart';
import 'package:net_builder/services/domain_vocabulary.dart';
import 'package:net_builder/services/nlu/slots.dart';

void main() {
  setUp(DomainVocabulary.reset);
  tearDown(DomainVocabulary.reset);

  group('everyday words resolve to what they stand for', () {
    test('group words name a device', () {
      expect(DomainVocabulary.deviceTypeForWord('staff'), 'pc');
      expect(DomainVocabulary.deviceTypeForWord('employees'), 'pc');
      expect(DomainVocabulary.deviceTypeForWord('guests'), 'pc');
      expect(DomainVocabulary.deviceTypeForWord('students'), 'pc');
      expect(DomainVocabulary.deviceTypeForWord('guest laptops'), 'laptop');
    });

    test('ordinary nouns for devices resolve', () {
      expect(DomainVocabulary.deviceTypeForWord('workstation'), 'pc');
      expect(DomainVocabulary.deviceTypeForWord('gateway'), 'router');
      expect(DomainVocabulary.deviceTypeForWord('wifi'), 'wireless');
      expect(DomainVocabulary.deviceTypeForWord('ip phone'), 'phone');
      expect(DomainVocabulary.deviceTypeForWord('cctv'), 'camera');
    });

    test('service words resolve, longest phrase first', () {
      expect(DomainVocabulary.serviceRoleForWord('website'), 'http');
      expect(DomainVocabulary.serviceRoleForWord('web server'), 'http');
      expect(DomainVocabulary.serviceRoleForWord('login'), 'aaa');
      expect(DomainVocabulary.serviceRoleForWord('shared folder'), 'ftp');
      expect(DomainVocabulary.serviceRoleForWord('name resolution'), 'dns');
    });

    test('place words resolve to a kind of site', () {
      expect(DomainVocabulary.siteKindForWord('HQ'), 'headquarters');
      expect(DomainVocabulary.siteKindForWord('branch'), 'branch');
      expect(DomainVocabulary.siteKindForWord('warehouse'), 'warehouse');
      expect(DomainVocabulary.siteKindForWord('classroom'), 'classroom');
    });

    test('size words resolve', () {
      expect(DomainVocabulary.sizeForWord('small'), 'small');
      expect(DomainVocabulary.sizeForWord('enterprise'), 'large');
      expect(DomainVocabulary.sizeForWord('tiny'), 'tiny');
    });

    test('a word that means nothing here resolves to nothing', () {
      expect(DomainVocabulary.deviceTypeForWord('banana'), '');
      expect(DomainVocabulary.serviceRoleForWord('banana'), '');
      expect(DomainVocabulary.deviceTypeForWord(''), '');
    });
  });

  group('it is conservative', () {
    test('it never remaps the load-bearing technical terms', () {
      // These are what the whole pipeline is built on. A "helpful" rewrite
      // here breaks every correctly-phrased brief in the app.
      for (final word in const [
        'server', 'router', 'switch', 'firewall', 'cloud', 'pc', 'laptop',
      ]) {
        expect(DomainVocabulary.learn(word, 'printer'), isFalse,
            reason: '$word must not be teachable');
      }
    });

    test('it refuses a concept it does not understand', () {
      expect(DomainVocabulary.learn('widget', 'flange'), isFalse);
      expect(DomainVocabulary.learn('widget', 'server'), isTrue);
    });

    test('a word is not learned twice under two meanings', () {
      expect(DomainVocabulary.learn('widget', 'pc'), isTrue);
      expect(DomainVocabulary.learn('widget', 'printer'), isTrue);
      expect(DomainVocabulary.deviceTypeForWord('widget'), 'printer');
    });
  });

  group('it learns from corrections', () {
    test('a taught word outranks the built-in table', () {
      // The user says "in our office, kiosk means a tablet, not a pc".
      expect(DomainVocabulary.deviceTypeForWord('kiosk'), '');
      expect(DomainVocabulary.learn('kiosk', 'tablet'), isTrue);
      expect(DomainVocabulary.deviceTypeForWord('kiosk'), 'tablet');
    });

    test('learned words survive a save and restore round trip', () {
      DomainVocabulary.learn('kiosk', 'tablet');
      DomainVocabulary.learn('front desk', 'pc');
      final saved = DomainVocabulary.snapshot();

      DomainVocabulary.reset();
      expect(DomainVocabulary.deviceTypeForWord('kiosk'), '');

      DomainVocabulary.restore(saved);
      expect(DomainVocabulary.deviceTypeForWord('kiosk'), 'tablet');
      expect(DomainVocabulary.deviceTypeForWord('front desk'), 'pc');
    });

    test('restoring rubbish changes nothing rather than poisoning the map', () {
      DomainVocabulary.restore(<dynamic, dynamic>{
        'kiosk': 'tablet',
        'broken': 42,
        'worse': 'not-a-concept',
        7: 'pc',
      });
      expect(DomainVocabulary.deviceTypeForWord('kiosk'), 'tablet');
      expect(DomainVocabulary.deviceTypeForWord('broken'), '');
      expect(DomainVocabulary.deviceTypeForWord('worse'), '');
    });

    test('a taught word starts counting devices', () {
      DomainVocabulary.learn('kiosk', 'tablet');
      final slots = BriefSlotPipeline.extract('lab', 'a shop with 6 kiosks');
      expect(slots.count('tablet'), 6,
          reason: 'a word taught once should count from then on');
    });
  });

  group('everyday wording reaches the plan', () {
    test('"staff" and "guest laptops" become real devices', () {
      final plan = NetworkIntent.parseSimple(
        'chat',
        'Build an office with 15 staff and 4 guest laptops.',
      );
      final names = plan.nodes.map((n) => '${n.name}:${n.type}').toSet();
      expect(plan.nodes.where((n) => n.type == 'pc'), hasLength(15),
          reason: 'the 15 staff should be 15 computers, got $names');
      expect(plan.nodes.where((n) => n.type == 'laptop'), hasLength(4),
          reason: 'the 4 guest laptops should be 4 laptops, got $names');
    });

    test('"a website and shared folders" become server roles', () {
      final roles = BriefSlotPipeline.extractRoles(
        'Set up a website and shared folders for the team.',
      );
      expect(roles, contains('http'));
      expect(roles, contains('ftp'));
    });

    test('naming a service with no server still provisions one', () {
      final slots = BriefSlotPipeline.extract(
        'office',
        'A small office that needs a website.',
      );
      expect(slots.count('server'), greaterThan(0),
          reason: 'a website with nothing to serve it is a dropped requirement');
    });

    test('a negated everyday count is rejected, not counted', () {
      final slots = BriefSlotPipeline.extract('lab', 'A lab with not 8 staff.');
      expect(slots.count('pc'), isNot(8));
    });

    test('a technical brief resolves exactly as it always did', () {
      // The important regression guard: additive means additive.
      final before = NetworkIntent.parseSimple(
        'chat',
        '2 routers, 3 switches, 4 servers and 10 PCs with OSPF area 0',
      );
      final nodes = before.nodes.map((n) => n.type).toList();
      expect(nodes.where((t) => t == 'router'), hasLength(2));
      expect(nodes.where((t) => t == 'switch'), hasLength(3));
      expect(nodes.where((t) => t == 'server'), hasLength(4));
      expect(nodes.where((t) => t == 'pc'), hasLength(10));
    });

    test('a word the pipeline already knew is never counted twice', () {
      // "computers" is both an everyday word and a technical keyword. Counting
      // it through both paths would make the merge rules do arithmetic.
      final slots = BriefSlotPipeline.extract('lab', 'A lab with 7 computers.');
      expect(slots.count('pc'), 7);
    });

    test('a site word does not invent a device', () {
      final slots = BriefSlotPipeline.extract(
        'lab',
        'A warehouse with 2 routers and 4 PCs.',
      );
      expect(slots.count('router'), 2);
      expect(slots.count('pc'), 4);
      expect(DomainVocabulary.siteKindForWord('warehouse'), 'warehouse');
    });
  });
}