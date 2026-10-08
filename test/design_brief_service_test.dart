import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:net_builder/models/design_brief.dart';
import 'package:net_builder/models/environment_profile.dart';
import 'package:net_builder/models/network_intent.dart';
import 'package:net_builder/services/design_brief_service.dart';
import 'package:net_builder/widgets/brief_card.dart';

NetworkIntent _plan({
  String routing = 'static',
  List<NetNode> nodes = const [
    NetNode(name: 'R1', type: 'router'),
    NetNode(name: 'R2', type: 'router'),
    NetNode(name: 'SW1', type: 'switch'),
    NetNode(name: 'PC1', type: 'pc'),
    NetNode(name: 'PC2', type: 'pc'),
  ],
  List<int> vlans = const [],
}) =>
    NetworkIntent(projectName: 'lab', nodes: nodes, routing: routing, vlans: vlans);

void main() {
  group('briefForTurn: text claims', () {
    test('a stated protocol fills routing with provenance', () {
      final turn = DesignBriefService.briefForTurn(
        normalizedText: 'use ospf for routing',
      );
      expect(turn.brief.value(DesignBrief.routing), 'ospf');
      expect(turn.brief.fact(DesignBrief.routing)!.display, 'OSPF');
      expect(turn.brief.fact(DesignBrief.routing)!.source, 'from your words');
      expect(turn.changed, isTrue);
      expect(turn.announced, contains('Routing: OSPF - from your words'));
    });

    test('a stated scale fills the slot and says which noun was used', () {
      final turn = DesignBriefService.briefForTurn(
        normalizedText: 'the network is for 40 employees',
      );
      expect(turn.brief.value(DesignBrief.scale), '40');
      expect(turn.brief.fact(DesignBrief.scale)!.display, '40 users');
    });

    test('a device count reads as devices, not people', () {
      final turn = DesignBriefService.briefForTurn(
        normalizedText: '50 pcs in the lab',
      );
      expect(turn.brief.value(DesignBrief.scale), '50');
      expect(turn.brief.fact(DesignBrief.scale)!.display, '50 devices');
    });

    test('"no vlans" and "one flat network" fill segmentation none', () {
      final a = DesignBriefService.briefForTurn(
        normalizedText: 'keep it simple, no vlans',
      );
      final b = DesignBriefService.briefForTurn(
        normalizedText: 'one flat network please',
      );
      expect(a.brief.value(DesignBrief.segmentation), 'none');
      expect(b.brief.value(DesignBrief.segmentation), 'none');
    });

    test('maximum security, wireless yes and no all register', () {
      expect(
        DesignBriefService.briefForTurn(
          normalizedText: 'make security maximum and wireless',
        ).brief.value(DesignBrief.security),
        'maximum',
      );
      expect(
        DesignBriefService.briefForTurn(
          normalizedText: 'wireless coverage for the whole floor',
        ).brief.value(DesignBrief.wireless),
        'yes',
      );
      expect(
        DesignBriefService.briefForTurn(
          normalizedText: 'wired only, no wireless',
        ).brief.value(DesignBrief.wireless),
        'no',
      );
    });

    test('a stated venue fills the venue slot', () {
      final turn = DesignBriefService.briefForTurn(
        normalizedText: 'this is for a school',
      );
      expect(turn.brief.value(DesignBrief.venue), 'school');
    });
  });

  group('briefForTurn: the plan must not masquerade as decisions', () {
    test('a plan-routing DEFAULT never fills the routing slot', () {
      // The parse defaults to static; the text never mentions routing.
      final turn = DesignBriefService.briefForTurn(
        normalizedText: '2 routers, 2 switches and 12 pcs',
        parsedPlan: _plan(routing: 'static'),
      );
      expect(turn.brief.has(DesignBrief.routing), isFalse);
    });

    test('plan routing fills only when the text was about routing', () {
      final turn = DesignBriefService.briefForTurn(
        normalizedText: 'with dynamic routing between the routers',
        parsedPlan: _plan(routing: 'ospf'),
      );
      expect(turn.brief.value(DesignBrief.routing), 'ospf');
      expect(
        turn.brief.fact(DesignBrief.routing)!.source,
        'from the protocol you named',
      );
    });

    test('plan VLANs fill only when the text was about vlans', () {
      final without = DesignBriefService.briefForTurn(
        normalizedText: '2 routers and 12 pcs',
        parsedPlan: _plan(vlans: [10, 20]),
      );
      expect(without.brief.has(DesignBrief.segmentation), isFalse);

      final withVlan = DesignBriefService.briefForTurn(
        normalizedText: '2 routers and 12 pcs with vlans',
        parsedPlan: _plan(vlans: [10, 20]),
      );
      expect(withVlan.brief.value(DesignBrief.segmentation), 'vlans');
      expect(withVlan.brief.fact(DesignBrief.segmentation)!.display,
          'VLANs 10, 20');
    });

    test('access points in the plan mean wireless was asked for', () {
      final turn = DesignBriefService.briefForTurn(
        normalizedText: '2 routers, 2 switches, 2 access points and 12 pcs',
        parsedPlan: _plan(nodes: const [
          NetNode(name: 'R1', type: 'router'),
          NetNode(name: 'AP1', type: 'access point'),
          NetNode(name: 'PC1', type: 'pc'),
        ]),
      );
      expect(turn.brief.value(DesignBrief.wireless), 'yes');
      expect(
        turn.brief.fact(DesignBrief.wireless)!.source,
        'the lab has access points',
      );
    });

    test('plan PCs give scale when the text mentions devices without numbers',
        () {
      final turn = DesignBriefService.briefForTurn(
        normalizedText: 'a lab with routers, switches and pcs',
        parsedPlan: _plan(),
      );
      expect(turn.brief.value(DesignBrief.scale), '2');
      expect(
        turn.brief.fact(DesignBrief.scale)!.source,
        'from the lab you described',
      );
    });
  });

  group('briefForTurn: profile and precedence', () {
    test('the profile fills unfilled slots with provenance', () {
      final turn = DesignBriefService.briefForTurn(
        normalizedText: 'use ospf',
        profile: const EnvironmentProfile(venue: 'office', scale: 20),
      );
      expect(turn.brief.value(DesignBrief.venue), 'office');
      expect(turn.brief.value(DesignBrief.scale), '20');
      expect(
        turn.brief.fact(DesignBrief.venue)!.source,
        'from your environment profile',
      );
      // But the user's words win where they spoke.
      expect(turn.brief.value(DesignBrief.routing), 'ospf');
    });

    test('the user beats the profile on the same slot', () {
      final turn = DesignBriefService.briefForTurn(
        normalizedText: '30 users',
        profile: const EnvironmentProfile(scale: 40),
      );
      expect(turn.brief.value(DesignBrief.scale), '30');
    });

    test('a later turn updates a fact and announces the change', () {
      final first = DesignBriefService.briefForTurn(
        normalizedText: '50 users',
      ).brief;
      final second = DesignBriefService.briefForTurn(
        previous: first,
        normalizedText: 'actually 40 users',
      );
      expect(second.changed, isTrue);
      expect(second.brief.value(DesignBrief.scale), '40');
      expect(second.announced, contains('Scale: 40 users - from your words'));
    });

    test('an unrelated turn changes nothing and announces nothing', () {
      final first = DesignBriefService.briefForTurn(
        normalizedText: '50 users with ospf',
      ).brief;
      final second = DesignBriefService.briefForTurn(
        previous: first,
        normalizedText: 'thanks',
      );
      expect(second.changed, isFalse);
      expect(second.announced, isEmpty);
      // A no-op turn does not even copy: the same brief instance comes back.
      expect(identical(second.brief, first), isTrue);
      expect(second.brief.sameFactsAs(first), isTrue);
    });
  });

  group('readiness', () {
    test('critical slots gate readiness', () {
      const empty = DesignBrief();
      expect(empty.ready, isFalse);
      expect(empty.missingCritical, containsAll(['scale', 'routing']));

      final filled = const DesignBrief().withFact(
        DesignBrief.scale,
        const BriefFact(value: '40', display: '40 users'),
      ).withFact(
        DesignBrief.routing,
        const BriefFact(value: 'ospf', display: 'OSPF'),
      );
      expect(filled.ready, isTrue);
      expect(filled.missingCritical, isEmpty);
    });

    test('JSON round trip preserves facts', () {
      final turn = DesignBriefService.briefForTurn(
        normalizedText: '2 routers with ospf for 40 users',
      );
      final decoded = DesignBrief.fromJson(turn.brief.toJson());
      expect(decoded.sameFactsAs(turn.brief), isTrue);
      expect(decoded.value(DesignBrief.routing), 'ospf');
    });
  });

  group('BriefCardWidget', () {
    testWidgets('shows filled facts with provenance and open chips',
        (tester) async {
      final brief = DesignBriefService.briefForTurn(
        normalizedText: 'use ospf for 40 users',
        profile: const EnvironmentProfile(venue: 'office'),
      ).brief;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: BriefCardWidget(brief: brief),
          ),
        ),
      ));

      expect(find.byKey(const ValueKey('brief-card')), findsOneWidget);
      expect(find.textContaining('OSPF'), findsWidgets);
      expect(find.textContaining('from your environment profile'),
          findsOneWidget);
      // Wireless and segmentation were never mentioned: open, and NOT
      // critical (only scale/routing are), so they render as muted chips.
      expect(find.byKey(const ValueKey('brief-open-wireless')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('brief-open-segmentation')),
        findsOneWidget,
      );
    });

    testWidgets('a brief with critical gaps says questions come first',
        (tester) async {
      final brief = DesignBriefService.briefForTurn(
        normalizedText: 'use ospf',
      ).brief;
      expect(brief.ready, isFalse);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: BriefCardWidget(brief: brief)),
        ),
      ));
      expect(find.textContaining('I will ask about the highlighted'),
          findsOneWidget);
    });

    testWidgets('a ready brief says so', (tester) async {
      final brief = DesignBriefService.briefForTurn(
        normalizedText: 'ospf for 40 users',
      ).brief;
      expect(brief.ready, isTrue);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: BriefCardWidget(brief: brief)),
        ),
      ));
      expect(find.textContaining('Enough to build'), findsOneWidget);
    });

    testWidgets('an empty brief shrinks away', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: BriefCardWidget(brief: const DesignBrief()),
          ),
        ),
      ));
      expect(find.byKey(const ValueKey('brief-card')), findsNothing);
    });
  });
}
