import 'package:flutter_test/flutter_test.dart';

import 'package:net_builder/models/network_intent.dart';
import 'package:net_builder/services/misparse_ledger.dart';
import 'package:net_builder/services/phrasing_memory_service.dart';

/// The ledger behind the tap-to-fix chips on the "Understood" card.
///
/// A correction is only worth recording if it REPLAYS: the brief that comes
/// back must parse to the plan the user actually asked for, otherwise the
/// lesson taught from it would teach the wrong thing. These tests pin the
/// rewriting (the user's own words first, the canonical plan as fallback)
/// and the counting that decides when a row is worth reviewing.
void main() {
  NetworkIntent plan(String text) => NetworkIntent.parseSimple('chat', text);

  group('a count correction edits the words the user actually used', () {
    test('the count is replaced in place, everything else is kept', () {
      final fixed = MisparseLedger.correctedBrief(
        original: '2 routers and 4 switches for the office',
        slot: 'count:router',
        value: '5',
        current: plan('2 routers and 4 switches'),
      );
      expect(fixed, '5 routers and 4 switches for the office');
    });

    test('the unit is kept as written, so nothing else shifts', () {
      final fixed = MisparseLedger.correctedBrief(
        original: 'make me 40 pcs',
        slot: 'count:pc',
        value: '25',
        current: plan('40 pcs'),
      );
      expect(fixed, 'make me 25 pcs');
    });

    test('a count the sentence never wrote falls back to the plan', () {
      // The card reads counts out of the PLAN, so a number the user did not
      // type has to be corrected where the card got it from, not dropped.
      final fixed = MisparseLedger.correctedBrief(
        original: 'a small office network',
        slot: 'count:pc',
        value: '30',
        current: plan('40 pcs and 2 switches'),
      );
      expect(fixed, contains('30 PCs'));
      expect(fixed, contains('2 switches'));
      expect(fixed, isNot(contains('40')));
    });
  });

  group('routing and VLAN corrections', () {
    test('adding routing to a sentence that never named one', () {
      final fixed = MisparseLedger.correctedBrief(
        original: '2 routers',
        slot: 'routing',
        value: 'ospf',
        current: plan('2 routers'),
      );
      expect(fixed, contains('routing ospf'));
      expect(NetworkIntent.parseSimple('chat', fixed!).routing, 'ospf');
    });

    test('switching a protocol that was named', () {
      final fixed = MisparseLedger.correctedBrief(
        original: '2 routers with ospf',
        slot: 'routing',
        value: 'static',
        current: plan('2 routers with ospf'),
      );
      expect(fixed, isNot(contains('ospf')));
      expect(fixed, contains('static'));
    });

    test('an unknown protocol is refused rather than guessed at', () {
      expect(
        MisparseLedger.correctedBrief(
          original: '2 routers',
          slot: 'routing',
          value: 'rip is best',
          current: plan('2 routers'),
        ),
        isNull,
      );
    });

    test('a VLAN number is replaced wherever it appears', () {
      final fixed = MisparseLedger.correctedBrief(
        original: 'put 4 switches in vlan 10 and vlan 20',
        slot: 'vlan:10',
        value: '30',
        current: plan('4 switches'),
      );
      expect(fixed, contains('vlan 30'));
      expect(fixed, isNot(contains('vlan 10')));
      expect(fixed, contains('vlan 20'));
    });
  });

  group('the brief a plan is described as', () {
    test('device counts, routing and VLANs are all written', () {
      final described = MisparseLedger.briefFromPlan(
        plan('2 routers, 4 switches, 50 PCs, routing ospf'),
      );
      expect(described, contains('2 routers'));
      expect(described, contains('4 switches'));
      expect(described, contains('50 PCs'));
      expect(described, contains('routing ospf'));
    });

    test('units are singular and plural the way a brief writes them', () {
      expect(MisparseLedger.unit('pc', 1), 'PC');
      expect(MisparseLedger.unit('pc', 40), 'PCs');
      expect(MisparseLedger.unit('switch', 1), 'switch');
      expect(MisparseLedger.unit('switch', 4), 'switches');
      expect(MisparseLedger.unit('wireless', 2), 'APs');
    });

    test('a plan with no devices has no brief to teach from', () {
      expect(
        MisparseLedger.briefFromPlan(const NetworkIntent(projectName: 'chat')),
        isEmpty,
      );
    });
  });

  group('a correction is counted before it is ever proposed', () {
    ({
      List<MisparseEntry> entries,
      MisparseEntry? entry,
      MisparseEntry? proposed,
    }) log(
      List<MisparseEntry> entries, {
      String original = 'make me a lab for fifty pcs',
      String corrected = '50 PCs, 2 switches, 2 routers',
      String slot = 'count:pc',
    }) => MisparseLedger.record(
      entries: entries,
      original: original,
      understood: '40 PCs, 2 switches, 2 routers',
      corrected: corrected,
      slot: slot,
      source: 'tap',
    );

    test('one sighting is just a row in the ledger', () {
      final out = log(const []);
      expect(out.entry!.status, 'ledger');
      expect(out.entry!.count, 1);
      expect(out.proposed, isNull);
    });

    test('the threshold moves the row to proposed exactly once', () {
      var entries = log(const []).entries;
      expect(entries.first.count, 1);
      while (entries.first.count < MisparseLedger.promoteAfter - 1) {
        final step = log(entries);
        expect(step.proposed, isNull, reason: 'not at the threshold yet');
        entries = step.entries;
      }
      final hit = log(entries);
      expect(hit.entry!.count, MisparseLedger.promoteAfter);
      expect(hit.entry!.status, 'proposed');
      expect(hit.proposed, isNotNull, reason: 'this sighting is the one');
      // Repeating it must not announce it a second time.
      final again = log(hit.entries);
      expect(again.proposed, isNull);
      expect(again.entry!.status, 'proposed');
    });

    test('the same words needing a DIFFERENT fix is a different row', () {
      final first = log(const []);
      final second = log(
        first.entries,
        corrected: '60 PCs, 2 switches, 2 routers',
      );
      expect(second.entries, hasLength(2));
      expect(second.entry!.count, 1);
      expect(second.entry!.status, 'ledger');
    });

    test('a row the user already taught keeps the status they gave it', () {
      const original = 'make me a lab for fifty pcs';
      final taught = MisparseEntry(
        key: PhrasingMemoryService.normalizeKey(original),
        original: original,
        understood: '40 PCs, 2 switches, 2 routers',
        corrected: '50 PCs, 2 switches, 2 routers',
        slot: 'count:pc',
        source: 'tap',
        status: 'taught',
        count: 3,
        createdAt: '2026-10-08T00:00:00.000',
        updatedAt: '2026-10-08T00:00:00.000',
      );
      final out = log([taught]);
      expect(out.entry!.count, 4, reason: 'it is still counted');
      expect(out.entry!.status, 'taught', reason: 'but not re-proposed');
      expect(out.proposed, isNull);
    });
  });
}
