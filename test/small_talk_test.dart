// Saying "hello" must not produce a network.
//
// The failure this guards against: small talk was parsed like any other
// brief, so a message that named no devices at all fell back to a default
// 1-router lab. The assistant then announced "here is the lab I understand"
// at someone who had only greeted it - a plan the user never asked for,
// confidently described back to them.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:net_builder/main.dart';
import 'package:net_builder/models/network_intent.dart';
import 'package:net_builder/services/scope_gate.dart';

void main() {
  group('small talk is recognised as small talk', () {
    test('greetings, thanks and shrugs are small talk', () {
      const greetings = [
        'hello',
        'hi',
        'Hey there',
        'good morning',
        'thanks',
        'thank you!',
        'ok',
        'cool',
        'bye',
      ];
      for (final g in greetings) {
        expect(ScopeGate.isSmallTalk(g), isTrue, reason: '"$g" is a greeting');
      }
    });

    test('questions about the assistant are small talk', () {
      expect(ScopeGate.isSmallTalk('who are you'), isTrue);
      expect(ScopeGate.isSmallTalk('what can you do'), isTrue);
      expect(ScopeGate.isSmallTalk('help me'), isTrue);
      expect(ScopeGate.isSmallTalk('how are you'), isTrue);
      expect(ScopeGate.isSmallTalk("how's it going"), isTrue);
    });

    test('an identity question about networking is still a brief', () {
      // The identity wording must not swallow a real question that carries
      // networking vocabulary.
      expect(
        ScopeGate.isSmallTalk('how are you verifying the OSPF neighbors'),
        isFalse,
      );
    });

    test('a greeting carrying a real request is NOT small talk', () {
      // "hi, build me a lab" is a build request wearing a greeting.
      expect(ScopeGate.isSmallTalk('hi, build me a lab'), isFalse);
      expect(ScopeGate.isSmallTalk('thanks - now add a second router'),
          isFalse);
      expect(ScopeGate.isSmallTalk('ok, 20 PCs and 3 switches'), isFalse);
    });

    test('a real brief is never small talk', () {
      const briefs = [
        '2 routers, 3 switches and 10 PCs',
        'build me a network',
        'a small office with 12 employees',
        'why is OSPF better than static routing?',
      ];
      for (final b in briefs) {
        expect(ScopeGate.isSmallTalk(b), isFalse, reason: '"$b" is a brief');
      }
    });

    test('an empty message is not small talk', () {
      expect(ScopeGate.isSmallTalk(''), isFalse);
      expect(ScopeGate.isSmallTalk('   '), isFalse);
    });

    test('a coding request is not small talk - it is declined', () {
      expect(ScopeGate.isSmallTalk('write me a python script'), isFalse);
      expect(ScopeGate.isOffTopic('write me a python script'), isTrue);
    });
  });

  group('the plan the parser builds', () {
    test('a greeting names no devices, so the parser is never asked', () {
      // This is the whole point: the chat skips the parse for small talk.
      // Asserting that the parser WOULD invent a lab documents exactly why
      // it must not be called.
      final invented = NetworkIntent.parseSimple('chat', 'hello');
      expect(invented.nodes, isNotEmpty,
          reason: 'if this ever empties, the gate may be unnecessary');
      expect(
        ScopeGate.isSmallTalk('hello'),
        isTrue,
        reason: 'the gate must stop that default reaching the user',
      );
    });

    test('an unspecified but real brief still gets the helpful default', () {
      // "build me a network" is vague, not small talk - the default plan plus
      // the question "which devices?" is the right answer there.
      expect(ScopeGate.isSmallTalk('build me a network'), isFalse);
      final plan = NetworkIntent.parseSimple('chat', 'build me a network');
      expect(plan.questions.join(' ').toLowerCase(), contains('which devices'));
    });
  });

  testWidgets('a greeting leaves the app with NO plan to describe',
      (tester) async {
    await tester.pumpWidget(const NetBuilderApp());
    await tester.pumpAndSettle();

    Future<void> say(String text) async {
      await tester.enterText(
        find.byWidgetPredicate(
          (w) => w is TextField && w.decoration?.labelText == 'Message',
        ),
        text,
      );
      await tester.pumpAndSettle();
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pumpAndSettle();
    }

    await say('hello');
    await tester.pumpAndSettle();

    // The plan card is the observable proof that a plan exists. After a
    // greeting there must be none - because the standing plan is what gets
    // shipped to the model, and a model handed a default lab will describe
    // it back ("here is the network I understand") to someone who only said
    // hello.
    expect(find.text('Understood'), findsNothing,
        reason: '"hello" must not create a plan');
    expect(find.textContaining('lab I understand'), findsNothing,
        reason: '"hello" must not be answered with a network');

    // A REAL brief on the same screen does produce one, so this is the gate
    // working and not the card being broken.
    await say('2 routers, 3 switches and 10 PCs');
    await tester.pumpAndSettle();
    expect(find.text('Understood'), findsOneWidget,
        reason: 'a real brief still gets a plan');
  });
}