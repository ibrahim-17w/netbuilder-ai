import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:net_builder/services/troubleshoot_flows.dart';

/// Tests for the interactive troubleshooting flows: every flow is walked
/// end to end on at least one path, one branch diverges per flow, unknown
/// answers re-ask, state survives a JSON round-trip, and the openers
/// respect what CasualEnglish.canonical does to symptom phrasings.
void main() {
  group('flow openers', () {
    test('the classic symptom opens the local ladder', () {
      expect(TroubleshootFlows.matchStart('my pc cannot ping anything'),
          'pc-unreachable');
      expect(TroubleshootFlows.matchStart('my pc has no connectivity'),
          'pc-unreachable');
      expect(TroubleshootFlows.matchStart('troubleshoot my connection'),
          'pc-unreachable');
    });

    test('a symptom that names its target stays with the corpus ladder', () {
      // The flows ask the questions an open symptom needs; a question that
      // already names where the ping dies is answered directly.
      expect(TroubleshootFlows.matchStart('PC1 cannot ping the gateway'),
          isNull);
      expect(TroubleshootFlows.matchStart('the pc cannot reach 8.8.8.8'),
          isNull);
      expect(TroubleshootFlows.matchStart('PC1 cannot ping PC2'), isNull);
    });

    test('internet trouble opens the WAN ladder, not the local one', () {
      // 'no internet' canonicalizes to 'no connectivity' - the raw words
      // must still decide the flow.
      expect(TroubleshootFlows.matchStart('no internet in the lab'),
          'no-internet');
      expect(TroubleshootFlows.matchStart('the pc cannot reach the internet'),
          'no-internet');
    });

    test('a configuration ask is not a symptom', () {
      expect(TroubleshootFlows.matchStart('how do I configure ospf'), isNull);
      expect(TroubleshootFlows.matchStart('what is a vlan'), isNull);
      expect(
        TroubleshootFlows.matchStart('give my pcs internet access'),
        isNull,
      );
    });

    test('the dropping symptom opens the intermittent ladder', () {
      expect(TroubleshootFlows.matchStart('the network keeps dropping'),
          'intermittent');
      expect(TroubleshootFlows.matchStart('it is intermittent'),
          'intermittent');
    });

    test('start rejects unknown flow ids', () {
      expect(TroubleshootFlows.start('nonsense'), isNull);
    });
  });

  group('the pc-unreachable ladder', () {
    FlowTurn walk(Map<String, dynamic> state, List<String> answers) {
      var turn = TroubleshootFlowEngine.advance(state, answers.first);
      for (final a in answers.skip(1)) {
        turn = TroubleshootFlowEngine.advance(turn.state, a);
      }
      return turn;
    }

    test('the dead-cable branch ends in a physical fix', () {
      final turn = walk(
        TroubleshootFlows.start('pc-unreachable')!,
        ['down/down'],
      );
      expect(turn.done, isTrue);
      expect(turn.fix, isNotNull);
      expect(turn.fix, contains('down/down'));
      expect(turn.fix, contains('show ip interface brief'));
    });

    test('the APIPA branch ends in the DHCP fix', () {
      final turn = walk(
        TroubleshootFlows.start('pc-unreachable')!,
        ['up/up', 'a 169.254.x.x address'],
      );
      expect(turn.done, isTrue);
      expect(turn.fix, contains('169.254'));
      expect(turn.fix!.toLowerCase(), contains('dhcp'));
    });

    test('the full healthy path ends in a routing-or-ACL verdict', () {
      final turn = walk(
        TroubleshootFlows.start('pc-unreachable')!,
        [
          'up/up',
          'a real address',
          'it replies',
          'destination host unreachable',
        ],
      );
      expect(turn.done, isTrue);
      expect(turn.fix, contains('show ip route'));
    });

    test('the same ladder diverges: a timeout lands on the ACL rung', () {
      final turn = walk(
        TroubleshootFlows.start('pc-unreachable')!,
        ['up/up', 'a real address', 'it replies', 'request timed out'],
      );
      expect(turn.fix, contains('show access-lists'));
    });

    test('every intermediate step offers tappable options', () {
      var turn = TroubleshootFlowEngine.advance(
        TroubleshootFlows.start('pc-unreachable')!,
        'up/up',
      );
      expect(turn.done, isFalse);
      expect(turn.options, isNotEmpty);
      expect(turn.prompt, contains('ipconfig'));
    });
  });

  group('the no-internet ladder', () {
    test('a dead gateway is refused to the local ladder', () {
      final turn = TroubleshootFlowEngine.advance(
        TroubleshootFlows.start('no-internet')!,
        'no',
      );
      expect(turn.done, isTrue);
      expect(turn.fix, contains('gateway'));
    });

    test('empty translations end in the PAT walkthrough', () {
      var turn = TroubleshootFlowEngine.advance(
        TroubleshootFlows.start('no-internet')!,
        'yes',
      );
      turn = TroubleshootFlowEngine.advance(turn.state, 'yes');
      turn = TroubleshootFlowEngine.advance(turn.state, 'it is empty');
      expect(turn.done, isTrue);
      expect(turn.fix, contains('overload'));
      expect(turn.fix, contains('ip nat inside source list'));
    });

    test('a DNS failure is the last rung, after NAT is proven', () {
      var turn = TroubleshootFlowEngine.advance(
        TroubleshootFlows.start('no-internet')!,
        'yes',
      );
      turn = TroubleshootFlowEngine.advance(turn.state, 'yes');
      turn = TroubleshootFlowEngine.advance(turn.state, 'it shows translations');
      turn = TroubleshootFlowEngine.advance(turn.state, 'it fails');
      expect(turn.done, isTrue);
      expect(turn.fix!.toLowerCase(), contains('dns'));
    });
  });

  group('the intermittent ladder', () {
    test('climbing CRCs end in the duplex/cable fix', () {
      var turn = TroubleshootFlowEngine.advance(
        TroubleshootFlows.start('intermittent')!,
        'wired',
      );
      turn = TroubleshootFlowEngine.advance(turn.state, 'errors climbing');
      expect(turn.done, isTrue);
      expect(turn.fix!.toLowerCase(), contains('duplex'));
    });

    test('idle drops pass through the topology-change rung', () {
      var turn = TroubleshootFlowEngine.advance(
        TroubleshootFlows.start('intermittent')!,
        'wired',
      );
      turn = TroubleshootFlowEngine.advance(turn.state, 'counters clean');
      turn = TroubleshootFlowEngine.advance(turn.state, 'at random idle moments');
      expect(turn.done, isFalse, reason: 'idle goes through the TCN rung');
      turn = TroubleshootFlowEngine.advance(turn.state, 'yes, topology changes');
      expect(turn.done, isTrue);
      expect(turn.fix, contains('portfast'));
    });

    test('a joining device ends in the duplicate-address fix', () {
      var turn = TroubleshootFlowEngine.advance(
        TroubleshootFlows.start('intermittent')!,
        'wired',
      );
      turn = TroubleshootFlowEngine.advance(turn.state, 'counters clean');
      turn = TroubleshootFlowEngine.advance(turn.state, 'when another device joins');
      expect(turn.done, isTrue);
      expect(turn.fix!.toLowerCase(), contains('duplicate'));
    });
  });

  group('flow mechanics', () {
    test('an unknown answer re-asks the same step with a hint', () {
      final first = TroubleshootFlows.start('pc-unreachable')!;
      final turn = TroubleshootFlowEngine.advance(first, 'purple giraffe');
      expect(turn.done, isFalse);
      expect(turn.state['step'], first['step']);
      expect(turn.prompt, contains('own words'));
    });

    test('state round-trips through JSON', () {
      var turn = TroubleshootFlowEngine.advance(
        TroubleshootFlows.start('pc-unreachable')!,
        'up/up',
      );
      final encoded = jsonEncode(turn.state);
      final restored = Map<String, dynamic>.from(jsonDecode(encoded) as Map);
      final next = TroubleshootFlowEngine.advance(restored, 'a real address');
      expect(next.done, isFalse);
      expect(next.prompt, contains('gateway'));
    });

    test('a corrupt state fails closed to an honest restart', () {
      final turn = TroubleshootFlowEngine.advance(
        {'flow': 'nonsense', 'step': 'x', 'data': <String, dynamic>{}},
        'up/up',
      );
      expect(turn.done, isTrue);
      expect(turn.prompt, contains('fresh'));
    });

    test('punctuation and case do not defeat an option match', () {
      var turn = TroubleshootFlowEngine.advance(
        TroubleshootFlows.start('pc-unreachable')!,
        'Up/Up.',
      );
      expect(turn.prompt, contains('ipconfig'));
    });
  });
}
