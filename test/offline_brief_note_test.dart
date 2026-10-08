import 'package:flutter_test/flutter_test.dart';

import 'package:net_builder/models/network_intent.dart';
import 'package:net_builder/services/clarification_service.dart';
import 'package:net_builder/services/offline_assistant_service.dart';

/// Two intents, one turn.
///
/// "2 routers and 4 switches, what is the best colour for the cable?" is a
/// brief AND a question. The offline assistant used to answer whichever half
/// its branch happened to catch first and drop the other on the floor: the
/// covered question got its explainer with no mention of the lab, the
/// uncovered one got a plan dump with no mention of the question.
///
/// These pin the fix, and - just as importantly - the lines it must NOT
/// cross: a plain build request still builds, and a yes/no turn about the
/// lab still gets the lab.
void main() {
  AssistantReply ask(
    String q, {
    NetworkIntent? plan,
    List<ClarificationQuestion> clarifying = const [],
  }) => OfflineAssistantService.reply(
    rawText: q,
    normalized: q.toLowerCase(),
    target: 'packet-tracer',
    plan: plan,
    clarifyingQuestions: clarifying,
  );

  final lab = NetworkIntent.parseSimple(
    'chat',
    '2 routers and 4 switches and 50 PCs',
  );
  const briefLine =
      'You are also describing a lab with 2 routers, 4 switches, 50 PCs';

  group('a counted question answers the question AND names the lab', () {
    test('the covered question keeps its answer', () {
      final r = ask('how does ospf work with 50 pcs', plan: lab);
      expect(r.intent, 'howto');
      expect(r.text, contains('router ospf 1'));
    });

    test('and the brief the turn also wrote is not thrown away', () {
      final r = ask('how does ospf work with 50 pcs', plan: lab);
      expect(r.text, contains(briefLine));
      expect(r.text, contains('build the .pkt'));
    });

    test('a question whose words sit mid-sentence counts as a question', () {
      // The WH-word is not at the start, so this used to read as a plain
      // build request and the question never reached any answer branch.
      final r = ask('50 pcs and 2 routers, how do I connect them', plan: lab);
      expect(r.text, contains(briefLine));
    });

    test('the brief that is not ready says it is not ready', () {
      final r = ask(
        'how does ospf work with 50 pcs',
        plan: lab,
        clarifying: const [
          ClarificationQuestion(
            id: 'scale',
            question: 'How many people will use it?',
            quickReplies: ['Home lab'],
            quickReplyValues: ['home'],
          ),
        ],
      );
      expect(r.text, contains('have not planned yet'));
      expect(r.text, contains('How many people will use it?'));
    });
  });

  group('an uncovered question is answered as a question, not as a build', () {
    test('the gap is said out loud instead of a plan dump', () {
      final r = ask('2 routers and 4 switches, where do I start?', plan: lab);
      expect(r.intent, isNot('build'));
      expect(r.text.toLowerCase(), contains('offline material'));
      expect(r.text, isNot(contains('Here is the lab I understand')));
    });

    test('and the lab still gets its line', () {
      final r = ask('2 routers and 4 switches, where do I start?', plan: lab);
      expect(r.text, contains(briefLine));
    });
  });

  group('the lines it does not cross', () {
    test('a plain build request still builds', () {
      final r = ask('2 routers and 4 switches for the lab', plan: lab);
      expect(r.intent, 'build');
      expect(r.text, contains('Here is the lab I understand'));
      expect(r.text, isNot(contains('You are also describing')));
    });

    test('a yes/no turn about the lab gets the lab, not a coverage gap', () {
      final r = ask('2 routers and 4 switches, is that enough?', plan: lab);
      expect(r.intent, 'build');
      expect(r.text, contains('Here is the lab I understand'));
      expect(r.text.toLowerCase(), isNot(contains('offline material')));
    });

    test('a turn with no lab in it has no lab to mention', () {
      final r = ask('how does ospf work');
      expect(r.text, isNot(contains('You are also describing')));
    });
  });
}
