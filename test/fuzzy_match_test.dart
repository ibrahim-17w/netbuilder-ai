// Fuzzy word matching: an unseen typo must not drop a device from the plan.
//
// Before this layer the typo handling was a fixed table, so a brief like
// "2 switshs and 10 pcs" read as ONE switch (the unknown word did not match,
// and the count fell back) - the app silently under-built. These pin both what
// it must fix and, just as importantly, what it must NOT touch.
import 'package:flutter_test/flutter_test.dart';
import 'package:net_builder/models/network_intent.dart';
import 'package:net_builder/services/casual_english.dart';
import 'package:net_builder/services/fuzzy_match.dart';

void main() {
  group('edit distance', () {
    test('known distances', () {
      expect(FuzzyMatch.distance('router', 'router'), 0);
      // A transposition is two edits to plain Levenshtein (no Damerau step).
      expect(FuzzyMatch.distance('rotuer', 'router'), 2);
      expect(FuzzyMatch.distance('switsh', 'switch'), 1);
      expect(FuzzyMatch.distance('routr', 'router'), 1);
      expect(FuzzyMatch.distance('pc', 'switch'), 5);
    });

    test('is symmetric', () {
      expect(
        FuzzyMatch.distance('router', 'route'),
        FuzzyMatch.distance('route', 'router'),
      );
    });
  });

  group('fuzzy correction', () {
    // Every one of these is a typo the old table did NOT contain.
    const shouldFix = <String, String>{
      'rotuer': 'router',
      'routre': 'router',
      'roter': 'router',
      'switsh': 'switch',
      'swtichs': 'switches',
      'switchs': 'switches',
      'srvr': 'server',
      'serser': 'server',
      'serve': 'server',
      'lapto': 'laptop',
      'printar': 'printer',
      'firewal': 'firewall',
      'vlaan': 'vlan',
      'ospff': 'ospf',
      'eigrp': 'eigrp',
      'gatewy': 'gateway',
      'trnuk': 'trunk',
    };

    shouldFix.forEach((typo, want) {
      test('"$typo" -> "$want"', () {
        expect(FuzzyMatch.correct(typo), want);
      });
    });

    test('plurals are re-pluralized correctly', () {
      expect(FuzzyMatch.correct('rotuers'), 'routers');
      expect(FuzzyMatch.correct('switshs'), 'switches');
      expect(FuzzyMatch.correct('servres'), 'servers');
      expect(FuzzyMatch.correct('labtops'), 'laptops');
    });
  });

  group('fuzzy correction must NOT fire', () {
    test('unrelated words are left alone', () {
      for (final word in [
        'hello',
        'please',
        'build',
        'network',
        'about',
        'thing',
        'make',
        'want',
        'blue',
        'cat',
        'hat',
      ]) {
        expect(FuzzyMatch.correct(word), isNull, reason: '"$word" was fuzzed');
      }
    });

    test('data and mixed-case tokens are protected', () {
      for (final token in [
        '192.168.1.0/24',
        'R1',
        'LabAdmin2026',
        'a@b.com',
        'g0/1',
        '4331',
      ]) {
        expect(FuzzyMatch.correct(token), isNull);
      }
    });

    test('a short word is not fuzzed into a different device', () {
      // `pc` is 2 letters -> budget 0, only an exact hit counts.
      expect(FuzzyMatch.correct('vc'), isNull);
      expect(FuzzyMatch.correct('cb'), isNull);
      // 3-letter acronyms are one edit apart and mean different things:
      // `aaa`/`asa`, `nat`/`mat`. They are NEVER fuzzed - only the curated
      // table may touch them (and it maps `osf`/`osfp` -> `ospf`).
      expect(FuzzyMatch.correct('aaa'), isNull);
      expect(FuzzyMatch.correct('osf'), isNull);
      expect(FuzzyMatch.correct('nat'), 'nat'); // exact term, not a fuzz
    });

    test(
      'the table, not the fuzzy layer, handles the dangerous short typos',
      () {
        // These live in the hand-written table on purpose: `osf` -> `ospf` is
        // one edit apart, which is too close to fuzz automatically.
        expect(CasualEnglish.normalize('osf routing'), 'ospf routing');
        expect(CasualEnglish.normalize('use osfp'), 'use ospf');
        // And `aaa` must survive as itself.
        expect(
          CasualEnglish.normalize('aaa on the vty lines'),
          'aaa on the vty lines',
        );
      },
    );

    test('the first letter must match', () {
      // `hat` is one edit from `nat` but starts differently.
      expect(FuzzyMatch.correct('hat'), isNull);
      expect(FuzzyMatch.correct('mrouter'), isNull);
    });
  });

  group('normalize uses the fuzzy layer as a fallback', () {
    test('an unseen device typo is corrected', () {
      expect(
        CasualEnglish.normalize('2 rotuers and 3 switshs'),
        '2 routers and 3 switches',
      );
    });

    test('known-table typos still map (table wins over distance)', () {
      // 'acess' -> 'access' changes the meaning and only the table knows it.
      expect(CasualEnglish.normalize('acess switch'), 'access switch');
    });

    test('addresses, models and mixed-case survive untouched', () {
      const text = 'R1 at 192.168.1.1/24 model 4331 password LabAdmin2026';
      expect(CasualEnglish.normalize(text), text);
    });
  });

  group('the planner understands real typo briefs', () {
    final briefs = <String, Map<String, int>>{
      // brief -> {device type: minimum expected}
      '2 rotuers and 2 switshs with 4 pcs': {'router': 2, 'switch': 2, 'pc': 4},
      '1 routr, 1 swtich and 3 pcs': {'router': 1, 'switch': 1, 'pc': 3},
      'two routers and a servr': {'router': 2, 'server': 1},
      '3 laptops and 2 priners': {'laptop': 3, 'printer': 2},
      '1 firewal and 2 switshes': {'firewall': 1, 'switch': 2},
      'a small office with a router, a switch and 5 pcs': {
        'router': 1,
        'switch': 1,
        'pc': 5,
      },
    };

    briefs.forEach((brief, want) {
      test('"$brief"', () {
        final intent = NetworkIntent.parseSimple(
          'chat',
          CasualEnglish.normalize(brief),
        );
        for (final entry in want.entries) {
          final count = intent.nodes.where((n) {
            final t = n.type;
            if (entry.key == 'router') {
              return t == 'router' || t == 'wireless-router';
            }
            return t == entry.key;
          }).length;
          expect(
            count,
            greaterThanOrEqualTo(entry.value),
            reason: 'brief "$brief" produced $count ${entry.key}(s)',
          );
        }
      });
    });
  });

  group('typos never damage data or invent devices', () {
    test('a password with a digit is untouched end to end', () {
      final out = CasualEnglish.normalize('ssh with password Lab2026 on R1');
      expect(out, contains('Lab2026'));
      expect(out, contains('R1'));
    });

    test('an unrelated word does not become a device', () {
      final intent = NetworkIntent.parseSimple(
        'chat',
        CasualEnglish.normalize('hello there build me a network'),
      );
      // No device words at all - the planner must not conjure one from
      // "hello"/"there"/"network".
      expect(intent.nodes.where((n) => n.type == 'printer'), isEmpty);
      expect(intent.nodes.where((n) => n.type == 'firewall'), isEmpty);
    });
  });
}
