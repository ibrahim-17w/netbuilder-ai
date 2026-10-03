import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:net_builder/models/network_intent.dart';
import 'package:net_builder/services/memory_service.dart';
import 'package:net_builder/services/nlu/slots.dart';
import 'package:net_builder/services/phrasing_memory_service.dart';
import 'package:net_builder/services/scope_gate.dart';

/// The golden set: real English phrasings and the parse they must produce.
///
/// This is the measurement harness for the NLU front-end.
///
/// * `contract` cases are what the app guarantees today and must never
///   regress - each one is asserted exactly.
/// * `knownGaps` characterize behavior that is WRONG but stable, so closing
///   a gap is a deliberate, noticed change (this test goes red the moment
///   someone fixes it, and the case then moves into `contract`).
/// * The drift guard proves [BriefSlotPipeline] and the offline parser
///   still read the same brief the same way - the whole point of wiring
///   one into the other.
///
/// Before any learned or trained component is trusted to change a parse,
/// it is measured against this file first.

/// (brief, expected node counts by type, expected routing, run drift guard).
typedef GoldenCase = (String, Map<String, int>, String?, bool);

int count(NetworkIntent intent, String type) =>
    intent.nodes.where((n) => n.type == type).length;

final List<GoldenCase> contract = [
  // --- quantity phrases -----------------------------------------------------
  (
    'Build a network with 3 routers, 2 switches and 10 PCs',
    {'router': 3, 'switch': 2, 'pc': 10, 'server': 0},
    null,
    true,
  ),
  // Spelled-out numbers are bridged to digits before parsing.
  (
    '2 routers, 2 switches and four pcs',
    {'router': 2, 'switch': 2, 'pc': 4},
    null,
    true,
  ),
  // --- bare mentions mean one ----------------------------------------------
  (
    'a router connected to a switch and a server for dhcp',
    {'router': 1, 'switch': 1, 'pc': 0, 'server': 1},
    null,
    true,
  ),
  // --- model numbers are not quantities ------------------------------------
  (
    'Cisco 2911 routers for the office',
    {'router': 1, 'switch': 0, 'server': 0},
    null,
    true,
  ),
  // --- explicit labels are authoritative -----------------------------------
  (
    'R1 and R2 connect to SW1 and SW2, one PC for testing',
    {'router': 2, 'switch': 2, 'pc': 1, 'server': 0},
    null,
    true,
  ),
  (
    'R1 serves SRV1 and SRV2',
    {'router': 1, 'switch': 0, 'pc': 0, 'server': 2},
    null,
    true,
  ),
  // --- per-site clauses multiply --------------------------------------------
  (
    'two branch offices, each with a router, a switch and 3 pcs',
    {'router': 2, 'switch': 2, 'pc': 6},
    null,
    true,
  ),
  // --- roles and AAA provision a server -------------------------------------
  (
    '1 router with dns and http',
    {'router': 1, 'switch': 0, 'pc': 0, 'server': 1},
    null,
    true,
  ),
  (
    'use tacacs+ for logins, 2 routers 2 switches 4 pcs',
    {'router': 2, 'switch': 2, 'pc': 4, 'server': 1},
    null,
    true,
  ),
  // --- other catalog kinds ---------------------------------------------------
  (
    '2 routers 2 switches 4 pcs with wifi',
    {'router': 2, 'switch': 2, 'pc': 4, 'wireless': 1},
    null,
    true,
  ),
  (
    '2 firewalls and 2 pcs behind a router',
    {'router': 1, 'switch': 0, 'pc': 2, 'firewall': 2, 'server': 0},
    null,
    true,
  ),
  (
    '12 PCs, 1 switch',
    {'pc': 12, 'switch': 1},
    null,
    true,
  ),
  // --- the tiny-office default ------------------------------------------------
  (
    'build me something for the office',
    {'router': 1, 'switch': 1, 'pc': 0, 'server': 0},
    null,
    true,
  ),
  // --- routing ----------------------------------------------------------------
  (
    '2 routers 2 switches 4 pcs, run ospf between them',
    {'router': 2, 'switch': 2, 'pc': 4},
    'ospf',
    true,
  ),
  // --- quantities stated across clauses ---------------------------------------
  // Distinct sites add up: the second floor's six and the ground floor's
  // four are ten access points, not six.
  (
    'the second floor needs 6 access points and the ground floor 4',
    {'wireless': 10},
    null,
    true,
  ),
  // A total restated as exactly-distributed site counts is still the total.
  (
    '6 access points, 3 on the second floor and 3 on the ground floor',
    {'wireless': 6},
    null,
    true,
  ),
  // The same site restating the same number adds nothing.
  (
    'the second floor needs 6 access points; the second floor needs 6',
    {'wireless': 6},
    null,
    true,
  ),
  // A site's count can also arrive in the NEXT sentence, not just the next
  // clause.
  (
    'The second floor needs 6 access points. The ground floor needs 4.',
    {'wireless': 10},
    null,
    true,
  ),
  // A rejected protocol with nothing positive behind it is not a selection:
  // routing stays the default rather than being read off the rejected word.
  (
    'no ospf for this lab, 2 routers',
    {'router': 2},
    'static',
    false,
  ),
  // A correction replaces the number it corrects.
  (
    'the second floor needs 6 access points, actually 8',
    {'wireless': 8},
    null,
    true,
  ),
  // An announced addition adds.
  (
    'the second floor needs 6 access points and 4 more',
    {'wireless': 10},
    null,
    true,
  ),
  // --- multi-site completion -------------------------------------------
  // Several sites with devices but no infrastructure of their own: each
  // site is given a router and its share of access switches instead of
  // leaving a link-less farm of endpoints.
  (
    'two physical sites and 20 PCs',
    {'router': 2, 'switch': 2, 'pc': 20},
    null,
    true,
  ),
  // "more than N" is a floor: the plan uses N+1 minimums.
  (
    'more than 1 router and 1 switch and 1 server',
    {'router': 2, 'switch': 1, 'server': 1},
    null,
    true,
  ),
  // --- routing negation, contrast and replacement ------------------------------
  (
    "Don't use OSPF; use EIGRP",
    {},
    'eigrp',
    false,
  ),
  (
    'use OSPF on the routers, not EIGRP',
    {},
    'ospf',
    false,
  ),
  // --- the sizing pack (brief expands before the parser sees it, so the
  //     drift guard is skipped: the pipeline reads the raw brief only).
  (
    '10 employees and two floors, build the network',
    {
      'router': 1,
      'switch': 2,
      'pc': 10,
      'server': 1,
      'wireless': 2,
      'firewall': 1,
      'cloud': 1,
    },
    null,
    false,
  ),
];

final List<GoldenCase> knownGaps = [
  // (empty - the multi-clause quantity gap moved into `contract` when the
  // slot pipeline learned to add quantities across distinct clauses/sites.)
];

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('golden set: a brief parses to the plan it describes', () {
    final all = [...contract, ...knownGaps];
    for (var i = 0; i < all.length; i++) {
      final (brief, expected, routing, _) = all[i];
      final gap = knownGaps.any((g) => g.$1 == brief);
      test('#${i + 1}${gap ? ' (known gap)' : ''}: "$brief"', () {
        final intent = NetworkIntent.parseSimple('golden', brief);
        for (final e in expected.entries) {
          expect(
            count(intent, e.key),
            e.value,
            reason: '${e.key} count for: $brief',
          );
        }
        if (routing != null) {
          expect(intent.routing, routing, reason: 'routing for: $brief');
        }
      });
    }
  });

  group('golden set: the slot pipeline and the parser never disagree', () {
    final guarded = [...contract, ...knownGaps].where((c) => c.$4);
    for (final (brief, _, _, _) in guarded) {
      test('"$brief"', () {
        final intent = NetworkIntent.parseSimple('golden', brief);
        final slots = BriefSlotPipeline.extract('golden', brief);
        for (final type in ['router', 'switch', 'pc', 'server']) {
          expect(
            count(intent, type),
            slots.count(type),
            reason: '$type: parser vs pipeline for: $brief',
          );
        }
      });
    }
  });

  group('golden set: the scope gate decides in the right direction', () {
    const declined = [
      'write me a python script to parse a csv file',
      "what's the weather today",
      "what's the capital of France",
      'explain javascript closures to me',
      'tell me a joke',
    ];
    const accepted = [
      'build the network for 10 employees and two floors',
      'how do I configure a trunk port on a 2960 switch',
      'R1 cannot ping R2 since the OSPF adjacency died',
      'vlan 10 for the guest access points',
      '2 routers and a switch for the lab',
      // The advisor's own questions use real-world gear vocabulary; none of
      // these may ever be declined as general advice.
      'should I use pppoe or dhcp on the wan',
      'is cgnat why my port forward does not work',
      'do I need a poe switch for the ceiling access points',
      'is a unifi dream machine enough for a small office',
    ];
    for (final msg in declined) {
      test('declines: "$msg"', () {
        expect(ScopeGate.isOffTopic(msg), isTrue);
      });
    }
    for (final msg in accepted) {
      test('accepts: "$msg"', () {
        expect(ScopeGate.isOffTopic(msg), isFalse);
      });
    }
  });

  group('golden set: learned phrasings replay, and never override counts', () {
    void teach() {
      PhrasingMemoryService.setIndex([
        (
          phrasing: PhrasingMemoryService.normalizeKey(
            'build us the network for our office',
          ),
          rewrite: '2 routers 2 switches 4 pcs',
        ),
      ]);
      addTearDown(PhrasingMemoryService.clearIndex);
    }

    test('the exact wording replays its resolved brief', () {
      teach();
      final intent = NetworkIntent.parseSimple(
        'golden',
        'Build us the network for our office!',
      );
      expect(count(intent, 'router'), 2);
      expect(count(intent, 'switch'), 2);
      expect(count(intent, 'pc'), 4);
    });

    test('a brief that states counts is parsed as written, never replayed',
        () {
      teach();
      final intent = NetworkIntent.parseSimple(
        'golden',
        '3 routers 2 switches 8 pcs',
      );
      expect(count(intent, 'router'), 3);
      expect(count(intent, 'switch'), 2);
      expect(count(intent, 'pc'), 8);
    });

    test('a near twin of a learned phrasing replays too', () {
      PhrasingMemoryService.setIndex([
        (
          phrasing: PhrasingMemoryService.normalizeKey(
            'design a network for our marketing floor with printers',
          ),
          rewrite: '2 routers 2 switches 6 pcs',
        ),
      ]);
      addTearDown(PhrasingMemoryService.clearIndex);
      final intent = NetworkIntent.parseSimple(
        'golden',
        'design a network for our marketing floor with printers and phones',
      );
      expect(count(intent, 'router'), 2);
      expect(count(intent, 'pc'), 6);
    });

    test('teaching memory makes the very next parse replay the lesson',
        () async {
      final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      await MemoryService.createSchema(db);
      addTearDown(() async {
        PhrasingMemoryService.clearIndex();
        await db.close();
      });
      final mem = MemoryService(injected: db);
      await mem.teachPhrasing(
        PhrasingMemoryService.normalizeKey('make me a lab for the class'),
        '2 routers 2 switches 6 pcs',
      );
      expect(PhrasingMemoryService.indexView, isNotEmpty,
          reason: 'teachPhrasing refreshes the live index');
      final intent = NetworkIntent.parseSimple(
        'golden',
        'make me a lab for the class',
      );
      expect(count(intent, 'router'), 2);
      expect(count(intent, 'switch'), 2);
      expect(count(intent, 'pc'), 6);
    });
  });

  group('golden set: a fuzzy memory match merges, never replaces', () {
    test('a near match keeps devices and services the new wording adds', () {
      PhrasingMemoryService.setIndex([
        (
          phrasing: PhrasingMemoryService.normalizeKey(
            'design a network for our marketing floor with printers',
          ),
          rewrite: '2 routers 2 switches 6 pcs',
        ),
      ]);
      addTearDown(PhrasingMemoryService.clearIndex);
      final intent = NetworkIntent.parseSimple(
        'golden',
        'design a network for our marketing floor with printers and phones'
        ' and a dhcp server',
      );
      expect(count(intent, 'router'), 2);
      expect(count(intent, 'pc'), 6);
      expect(
        count(intent, 'printer'),
        1,
        reason: 'the new wording names printers; the match must not drop them',
      );
      expect(count(intent, 'phone'), 1);
      final srv = intent.nodes.where((n) => n.type == 'server').toList();
      expect(srv, hasLength(1));
      expect(
        srv.single.services,
        contains('dhcp'),
        reason: 'the service the new wording asked for must survive',
      );
    });

    test('an explicit current instruction beats the older lesson', () {
      PhrasingMemoryService.setIndex([
        (
          phrasing: PhrasingMemoryService.normalizeKey(
            'design a network for our marketing floor',
          ),
          rewrite: '2 routers 2 switches 6 pcs with ospf',
        ),
      ]);
      addTearDown(PhrasingMemoryService.clearIndex);
      final intent = NetworkIntent.parseSimple(
        'golden',
        'design a network for our marketing floor with eigrp instead of '
        'ospf',
      );
      expect(count(intent, 'router'), 2);
      expect(
        intent.routing,
        'eigrp',
        reason: 'the request said "instead of ospf"; the lesson says ospf',
      );
    });

    test('stating device counts is parsed as written, never merged', () {
      PhrasingMemoryService.setIndex([
        (
          phrasing: PhrasingMemoryService.normalizeKey(
            'design a network for our marketing floor',
          ),
          rewrite: '2 routers 2 switches 6 pcs',
        ),
      ]);
      addTearDown(PhrasingMemoryService.clearIndex);
      final intent = NetworkIntent.parseSimple(
        'golden',
        'design a network for our marketing floor with 3 routers and 5 pcs',
      );
      expect(count(intent, 'router'), 3);
      expect(count(intent, 'pc'), 5);
      expect(
        count(intent, 'switch'),
        0,
        reason: 'the remembered 2 switches must not join a brief that states '
            'its own counts',
      );
    });

    test('addresses, interfaces and secrets survive the merge', () {
      PhrasingMemoryService.setIndex([
        (
          phrasing: PhrasingMemoryService.normalizeKey(
            'set up the training lab network',
          ),
          rewrite: '2 routers 2 switches 6 pcs',
        ),
      ]);
      addTearDown(PhrasingMemoryService.clearIndex);
      final intent = NetworkIntent.parseSimple(
        'golden',
        'set up the training lab network with tacacs logins using shared '
        'key S3cret42, R1 g0/0 to R2 g0/0, LAN 192.168.9.0/24',
      );
      expect(count(intent, 'router'), 2);
      expect(count(intent, 'pc'), 6);
      expect(intent.security.aaa, isTrue);
      expect(
        (intent.security.aaaPassword ?? '').toLowerCase(),
        's3cret42',
        reason: 'the supplied key still reaches the security intent',
      );
      expect(
        intent.links.any(
          (l) => l.a == 'R1' && l.aIf == 'g0/0' && l.b == 'R2',
        ),
        isTrue,
        reason: 'the interfaces the request named are honoured',
      );
      expect(
        intent.addressing.any((a) => a.ipCidr.startsWith('192.168.9.')),
        isTrue,
        reason: 'the requested subnet still reaches the addressing plan',
      );
      expect(
        intent.notes.join(' '),
        isNot(contains('S3cret42')),
        reason: 'the quoted brief in the notes stays redacted',
      );
    });

    test('an uncertain match asks for confirmation instead of deciding', () {
      PhrasingMemoryService.setIndex([
        (
          phrasing: PhrasingMemoryService.normalizeKey(
            'design a secure network for our marketing floor with printers',
          ),
          rewrite: '2 routers 2 switches 6 pcs',
        ),
      ]);
      addTearDown(PhrasingMemoryService.clearIndex);
      final intent = NetworkIntent.parseSimple(
        'golden',
        'design a network for our marketing floor with printers and phones',
      );
      expect(
        intent.questions.where((q) => q.toLowerCase().contains('confirm')),
        isNotEmpty,
        reason: 'a partial-coverage match must not stay silent',
      );
    });
  });

  group('golden set: confidence reflects what was understood', () {
    test('a detailed brief is more confident than a vague one', () {
      final detailed = NetworkIntent.parseSimple(
        'c',
        '2 routers, 2 switches, 4 pcs with OSPF on 192.168.1.0/24',
      );
      final vague = NetworkIntent.parseSimple('c', 'build something nice');
      expect(detailed.confidence, greaterThan(vague.confidence));
      expect(detailed.confidence, greaterThanOrEqualTo(0.75));
    });

    test('the tiny-office default states its assumption and asks', () {
      final intent = NetworkIntent.parseSimple(
        'c',
        'build me something for the office',
      );
      expect(
        intent.nodes.where((n) => n.type == 'router'),
        hasLength(1),
        reason: 'the fallback pair still builds',
      );
      expect(
        intent.assumptions.any((a) => a.contains('assumed')),
        isTrue,
        reason: 'a guessed plan says it is a guess',
      );
      expect(
        intent.questions,
        isNotEmpty,
        reason: 'the guess is visible as an open question',
      );
    });

    test('a brief that states its details carries no default question', () {
      final intent = NetworkIntent.parseSimple(
        'c',
        '2 routers 2 switches 4 pcs with ospf',
      );
      expect(intent.questions, isEmpty);
      expect(intent.confidence, greaterThanOrEqualTo(0.7));
    });
  });

  group('golden set: adversarial probes on the follow-up path', () {
    test('a follow-up protocol change reads negation and replacement', () {
      final statics = NetworkIntent.parseSimple('p', '2 routers 4 pcs');
      expect(statics.routing, 'static');
      final changed = NetworkIntent.applyFollowUpChange(
        previous: statics,
        brief: 'use eigrp instead of ospf',
      );
      expect(changed, isNotNull);
      expect(
        changed!.routing,
        'eigrp',
        reason: 'the instruction selects eigrp; ospf is only mentioned to '
            'reject it',
      );
      expect(changed.nodes.length, statics.nodes.length);
    });

    test('a rejected protocol alone changes nothing', () {
      final ospf = NetworkIntent.parseSimple('p', '2 routers with ospf');
      expect(
        NetworkIntent.applyFollowUpChange(previous: ospf, brief: 'not ospf'),
        isNull,
        reason: 'no positive instruction means no change to apply',
      );
    });
  });
}
