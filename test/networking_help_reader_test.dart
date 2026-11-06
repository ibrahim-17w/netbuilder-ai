import 'package:flutter_test/flutter_test.dart';

import 'package:net_builder/models/network_intent.dart';
import 'package:net_builder/services/networking_help_reader.dart';

/// Networking help that must be answered, never planned and never built.
///
/// "Explain VLANs" with a lab on the table used to re-plan the lab; a bare
/// topic used to become a device. These pin the help reader, the follow-up
/// reader, and the planner's non-planning classification together.
void main() {
  group('NetworkingHelpReader.matches', () {
    test('help asks are recognized', () {
      const yes = [
        'explain vlans',
        'what is ospf?',
        'how do I configure dhcp on a cisco router?',
        'how to subnet 192.168.1.0/24',
        'my pc cannot ping the gateway',
        'no internet after adding a second switch',
        'help me troubleshoot why dns resolution fails',
        'teach me stp',
        'walk me through configuring a trunk port',
        'and vlans?',
        'why stp?',
        'give me an example',
        'what does that mean?',
      ];
      for (final text in yes) {
        expect(NetworkingHelpReader.matches(text), isTrue, reason: text);
      }
    });

    test('build and change requests are not help asks', () {
      const no = [
        '2 routers and 4 switches',
        'build the .pkt',
        'add another switch',
        'use ospf instead',
        'make it 40 PCs',
        'create a vlan 10 for guests',
        'hello',
        'build a network with 3 switches and 30 pcs',
      ];
      for (final text in no) {
        expect(NetworkingHelpReader.matches(text), isFalse, reason: text);
      }
    });

    test('a topical question with counts still plans (mixed ask)', () {
      // The count makes it a specification: the brief note carries the lab
      // while the question is answered - it is not swallowed as pure help.
      expect(
        NetworkingHelpReader.matches(
          '2 routers and 4 switches, is that enough?',
        ),
        isFalse,
      );
    });
  });

  group('NetworkingHelpReader.isFollowup', () {
    test('short follow-ups are recognized', () {
      const yes = [
        'give me an example',
        'show me an example',
        'explain it more',
        'tell me more',
        'what next?',
        'what does that mean',
        'continue',
        'go on',
      ];
      for (final text in yes) {
        expect(NetworkingHelpReader.isFollowup(text), isTrue, reason: text);
      }
      expect(NetworkingHelpReader.isFollowup('build the .pkt'), isFalse);
    });
  });

  group('NetworkingHelpReader.asksForExplanation', () {
    test('questions and explanations are distinct from a topic answer', () {
      expect(
        NetworkingHelpReader.asksForExplanation(
          'why is OSPF better than static routing?',
        ),
        isTrue,
      );
      expect(NetworkingHelpReader.asksForExplanation('OSPF'), isFalse);
    });
  });

  group('classifyBrief treats help as howto', () {
    test('help-shaped briefs are classified howto', () {
      const howto = [
        'explain vlans',
        'what is a firewall?',
        'how do I configure ospf?',
        'my pc cannot ping anything',
      ];
      for (final brief in howto) {
        expect(NetworkIntent.classifyBrief(brief), 'howto', reason: brief);
      }
    });

    test('a build brief still classifies as build', () {
      expect(NetworkIntent.classifyBrief('2 routers and 4 switches'), 'build');
    });
  });

  group('followUp keeps the plan for help asks', () {
    test('a help question does not overwrite a standing lab', () {
      final standing = NetworkIntent.parseSimple('p', '2 routers 4 switches');
      final outcome = NetworkIntent.followUp(
        previous: standing,
        previousBrief: '2 routers 4 switches',
        brief: 'explain vlans',
        parsed: NetworkIntent.parseSimple('p', 'explain vlans'),
        project: 'p',
      );
      expect(outcome.plan.nodes.length, standing.nodes.length);
      expect(outcome.brief, '2 routers 4 switches');
    });

    test('a help question with no plan does not invent one', () {
      final outcome = NetworkIntent.followUp(
        previous: null,
        previousBrief: '',
        brief: 'what is ospf?',
        parsed: NetworkIntent.parseSimple('p', 'what is ospf?'),
        project: 'p',
      );
      expect(outcome.plan.nodes, isEmpty);
    });
  });
}
