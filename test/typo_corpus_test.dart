// A wider corpus of realistic typo briefs, run end-to-end through the
// normalizer and the planner. These are the shapes a person actually types
// under time pressure - adjacent-key slips, transpositions, dropped vowels,
// missing letters - and before the fuzzy layer most of them silently
// under-built the network.
import 'package:flutter_test/flutter_test.dart';
import 'package:net_builder/models/network_intent.dart';
import 'package:net_builder/services/casual_english.dart';

void main() {
  final corpus = <String, Map<String, int>>{
    // brief -> {device type: exact expected count}
    '4 rotuers and 4 switshs with OSPF and 20 pcs': {
      'router': 4,
      'switch': 4,
      'pc': 20,
    },
    '1 routr with 2 swtich and 6 pc': {'router': 1, 'switch': 2, 'pc': 6},
    'six roters, 3 swiches and 12 pcs': {'router': 6, 'switch': 3, 'pc': 12},
    'a swich, a routar and a sevrer': {'router': 1, 'switch': 1, 'server': 1},
    '2 firewals and 2 switshes': {'firewall': 2, 'switch': 2},
    '3 labtops and 2 printars': {'laptop': 3, 'printer': 2},
    '10 pcs and a srvr': {'pc': 10, 'server': 1},
    '2 routre and 2 swtich': {'router': 2, 'switch': 2},
    '5 pss and 2 routrs': {'pc': 5, 'router': 2},
    'a printr, a servre and 4 pcs': {'printer': 1, 'server': 1, 'pc': 4},
  };

  corpus.forEach((brief, want) {
    test('"$brief"', () {
      final intent = NetworkIntent.parseSimple(
        'chat',
        CasualEnglish.normalize(brief),
      );
      final counts = <String, int>{};
      for (final n in intent.nodes) {
        counts[n.type] = (counts[n.type] ?? 0) + 1;
      }
      want.forEach((type, count) {
        expect(
          counts[type] ?? 0,
          count,
          reason: '"$brief" -> $counts (wanted $type=$count)',
        );
      });
    });
  });

  test('a typo never changes an address, a model or a password', () {
    // Punctuation is dropped by design (it carries no data), but every VALUE
    // must survive byte-for-byte.
    const brief =
        '2 routers at 192.168.1.1/24 and 10.0.0.0/30, model 4331, '
        'password LabAdmin2026';
    final out = CasualEnglish.normalize(brief);
    for (final value in const [
      '192.168.1.1/24',
      '10.0.0.0/30',
      '4331',
      'LabAdmin2026',
    ]) {
      expect(out, contains(value));
    }
    expect(out, startsWith('2 routers'));
  });

  test('the app is idempotent: normalizing twice changes nothing', () {
    const brief = '4 rotuers and 4 switshs with 20 pcs';
    final once = CasualEnglish.normalize(brief);
    final twice = CasualEnglish.normalize(once);
    expect(twice, once);
  });
}
