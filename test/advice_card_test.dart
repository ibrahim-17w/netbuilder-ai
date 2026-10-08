import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:net_builder/models/chat_message.dart';
import 'package:net_builder/services/offline_assistant_service.dart';
import 'package:net_builder/widgets/advice_card.dart';

/// The advice card: the structured advice answer becomes a persisted,
/// tappable card instead of a markdown table.
void main() {
  group('the reply carries structured advice', () {
    test('an advice reply exposes its parts', () {
      final r = OfflineAssistantService.reply(
        rawText: 'how many access points do i need for 40 users?',
        normalized: 'how many access points do i need for 40 users?',
        target: 'packet-tracer',
      );
      expect(r.intent, 'advice');
      expect(r.advice, isNotNull);
      expect(r.advice!.topic, 'ap_selection');
      expect(r.advice!.recommendation, isNotEmpty);
      expect(r.advice!.options, isNotEmpty);
      expect(r.advice!.planBrief, isNull,
          reason: 'the message names no lab, so there is nothing to re-plan');
    });
  });

  group('persistence', () {
    test('advice_card and pkt_open survive the allowlist round trip', () {
      const advice = ChatAction(
        kind: 'advice_card',
        summary: 'Design advice',
        payload: {
          'topic': 'ap_selection',
          'recommendation': 'Use wired APs.',
          'options': [
            {'label': 'Wired APs', 'chooseWhen': 'cable can be run', 'tradeOff': 'cabling cost'},
          ],
          'reasons': ['40 devices is past one AP'],
          'nextStep': 'Tell me the floor count',
          'planBrief': 'Build a home network with 1 wireless router and 4 PCs',
          'basis': 'the lab on the table',
        },
      );
      const open = ChatAction(
        kind: 'pkt_open',
        summary: 'Open in Packet Tracer',
        payload: {'path': r'C:\labs\office.pkt', 'name': 'office.pkt'},
      );
      // The round trip is what a conversation reopen does: toMap -> JSON ->
      // parseList. A kind missing from `supported` is dropped here, which is
      // how the open card used to silently vanish.
      final encoded =
          jsonEncode([advice.toMap(), open.toMap()]);
      final decoded = ChatAction.parseList(jsonDecode(encoded));
      expect(decoded.map((a) => a.kind), containsAll(['advice_card', 'pkt_open']));
      expect(decoded.length, 2);
      expect(decoded.where((a) => a.kind == 'advice_card').first.label,
          contains('Design advice'));
      expect(
        decoded.where((a) => a.kind == 'advice_card').first.payload['options'],
        isA<List>(),
      );
    });
  });

  group('widget', () {
    Map<String, dynamic> payload({
      String planBrief = 'Build a home network with 1 wireless router and 4 PCs',
    }) =>
        {
          'topic': 'ap_selection',
          'kind': 'sizing',
          'recommendation':
              'Wired access points beat mesh for anything larger than a flat.',
          'options': [
            {
              'label': 'Wired ceiling APs + PoE switch',
              'chooseWhen': 'more than ~30 devices',
              'tradeOff': 'needs cabling to each AP',
            },
            {
              'label': 'Mesh kit (wireless backhaul)',
              'chooseWhen': 'no way to run cable',
              'tradeOff': 'each hop loses roughly half the throughput',
            },
          ],
          'reasons': ['About 40 active devices: that is 2 AP(s) at the dense end.'],
          'nextStep': 'Give me the floor count.',
          'planBrief': planBrief,
          'basis': 'the lab on the table, and the way the simulators behave',
        };

    testWidgets('renders the recommendation highlighted with a Plan this',
        (tester) async {
      var planTapped = 0;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: AdviceCardWidget(
              payload: payload(),
              onPlanThis: () => planTapped++,
            ),
          ),
        ),
      ));

      expect(find.byKey(const ValueKey('advice-card')), findsOneWidget);
      // The card is the ACTION surface: the recommendation as the takeaway
      // plus the button. The options, reasons and basis stay in the markdown
      // answer above it - the card does not repeat them.
      expect(
        find.textContaining('Wired access points beat mesh'),
        findsOneWidget,
      );
      expect(find.textContaining('Choose it when'), findsNothing);
      expect(find.textContaining('Based on:'), findsNothing);
      expect(find.textContaining('Next step:'), findsNothing);

      final plan = find.byKey(const ValueKey('advice-plan-this'));
      expect(plan, findsOneWidget);
      await tester.tap(plan);
      expect(planTapped, 1);
    });

    testWidgets('no planBrief, no button', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: AdviceCardWidget(payload: payload(planBrief: '')),
          ),
        ),
      ));
      expect(find.byKey(const ValueKey('advice-plan-this')), findsNothing);
    });
  });
}
