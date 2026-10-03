import 'package:flutter_test/flutter_test.dart';
import 'package:net_builder/services/build_request_reader.dart';
import 'package:net_builder/services/chat_service.dart';

/// "Build the .pkt" must mean the same thing with a key as without one.
/// These tests pin both halves of that: the deterministic reader that runs
/// before any model, and the prompt line that teaches a model to propose
/// the build when the phrasing is its to interpret.
void main() {
  group('BuildRequestReader', () {
    test('a pure build request is caught, however it is phrased', () {
      const yes = [
        'build the .pkt',
        'Build the .pkt',
        'build the pkt',
        'build a pkt',
        'compile the pkt',
        'generate the pkt',
        'build the pkt file',
        'can you build the .pkt',
        'please compile the lab file',
        'generate the packet tracer file',
        'make the file',
        'write the topology',
        'hey build the pkt',
      ];
      for (final text in yes) {
        expect(BuildRequestReader.matches(text), isTrue, reason: text);
      }
    });

    test('questions, refusals and plan-changing asks are NOT executed', () {
      const no = [
        '',
        'hello',
        'build it', // an order with no object - "it" is not a file
        'how do I build the .pkt?', // a question to answer
        'what should I build?',
        'is the .pkt built?',
        "don't build the .pkt yet", // a deferral
        'never build the pkt',
        'build the .pkt for 2 routers', // changes the plan, then builds
        'explain how to build pkt files',
        '/build', // the slash form is the command path
        '2 routers and 4 switches',
      ];
      for (final text in no) {
        expect(BuildRequestReader.matches(text), isFalse, reason: text);
      }
    });

    test('multi-line text is never executed as a build', () {
      expect(BuildRequestReader.matches('build the .pkt\nand also'), isFalse);
    });
  });

  group('the model path is told how to build', () {
    test('systemContext pins the pkt_generate action', () {
      final prompt = ChatService.systemContext(
        target: 'packet-tracer',
        rulePacks: '',
        learnedRules: const [],
        preferences: const {},
        knownBlockers: const [],
        unsupportedCapabilities: const [],
        liveState: '',
      );
      expect(prompt, contains('{"kind":"pkt_generate"}'));
      expect(prompt, contains('Never claim a file was built in prose'));
      // The action must survive the parse into a card the user can tap.
      final parsed = ChatService.parseReply(
        '{"reply":"Building now","actions":[{"kind":"pkt_generate"}],'
        '"questions":[]}',
      );
      expect(parsed.actions, hasLength(1));
      expect(parsed.actions.single.kind, 'pkt_generate');
    });
  });
}
