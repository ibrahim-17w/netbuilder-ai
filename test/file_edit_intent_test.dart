import 'package:flutter_test/flutter_test.dart';
import 'package:net_builder/models/chat_message.dart';
import 'package:net_builder/services/context_budget.dart';
import 'package:net_builder/services/conversation_memory.dart';
import 'package:net_builder/services/file_edit_intent.dart';
import 'package:net_builder/services/session_state.dart';

/// "Edit it" used to mean "build another one".
///
/// The app remembers the file it produced, and a request that points at that
/// file edits it - never quietly writing a second .pkt next to the first. The
/// choice is offered in exactly one case: several files this conversation
/// produced and none of them named.
void main() {
  group('what a turn means for the file', () {
    FileEditIntent read(String text, {int candidates = 1}) =>
        FileEditIntentReader.read(
          text,
          hasArtifact: true,
          candidates: candidates,
        );

    test('an edit request that names the file IS that edit', () {
      // The user said what they wanted: "edit the file and make one server an
      // AAA server" is an instruction to change the file, and asking "edit it
      // or create a new one?" reads like the app did not listen.
      for (final phrase in [
        'edit it',
        'edit that',
        'change it',
        'modify the file',
        'update the project',
        'add another switch to it',
        'fix it',
        'make it 3 routers',
        'can you edit that',
        'add 2 servers to the lab',
        'tweak it',
        'edit the file and make one server an AAA server and another '
            'server as dhcp server',
      ]) {
        expect(read(phrase), FileEditIntent.editExisting, reason: phrase);
      }
    });

    test('several files and none named is the only genuine ambiguity', () {
      // Three builds in one conversation and a bare "edit it": only the user
      // can say which file, so the app asks.
      for (final phrase in [
        'edit it',
        'change the file',
        'add another switch to it',
        'fix it',
      ]) {
        expect(
          read(phrase, candidates: 3),
          FileEditIntent.ambiguous,
          reason: phrase,
        );
      }
    });

    test('a bare pointer with nothing to do is a question about the file', () {
      for (final phrase in ['that file?', 'what about this one?']) {
        expect(read(phrase), FileEditIntent.ambiguous, reason: phrase);
      }
    });

    test('"the same file" is an edit, not a question', () {
      for (final phrase in [
        'edit the same file',
        'update the existing project in place',
        'change the current file',
        'add a switch to the one I just made',
      ]) {
        expect(read(phrase), FileEditIntent.editExisting, reason: phrase);
      }
    });

    test('"a new one" is a new file, and says so', () {
      for (final phrase in [
        'make a new file',
        'create a new one',
        'build a fresh copy',
        'give me a separate project',
        'another file please',
        'a new version of the lab',
      ]) {
        expect(read(phrase), FileEditIntent.createNew, reason: phrase);
      }
    });

    test('ordinary conversation is not a file instruction', () {
      for (final phrase in [
        'what is ospf?',
        'why is PC3 down',
        'thanks',
        'yes please',
        'what did I ask you to build?',
        '2 routers and 4 switches',
      ]) {
        expect(read(phrase), FileEditIntent.none, reason: phrase);
      }
    });

    test('with no file yet there is nothing to edit', () {
      for (final phrase in ['edit it', 'change the file', 'make a new one']) {
        expect(
          FileEditIntentReader.read(phrase, hasArtifact: false),
          FileEditIntent.none,
          reason: phrase,
        );
      }
    });

    test('the choice names the file and offers both ways', () {
      final actions = FileEditIntentReader.choiceActions(
        path: 'C:/out/serial-lab.pkt',
        name: 'serial-lab.pkt',
        devices: 20,
        links: 19,
        revision: 'a1b2c3d4',
        project: 'serial-lab',
        blocking: 2,
      );
      expect(actions, hasLength(2));
      expect(actions.first.kind, 'pkt_edit');
      expect(actions.first.payload['path'], 'C:/out/serial-lab.pkt');
      expect(actions.first.summary, contains('serial-lab.pkt'));
      expect(actions.first.summary.toLowerCase(), contains('backup'));
      expect(actions.last.kind, 'pkt_generate');
      expect(actions.last.payload['mode'], 'new');
      // Both choices carry the plan version they were written against, so
      // neither can be run against a plan the user never saw.
      expect(actions.first.payload['revision'], 'a1b2c3d4');
      expect(actions.last.payload['revision'], 'a1b2c3d4');
      expect(actions.last.payload['devices'], 20);
      expect(actions.last.payload['links'], 19);
      expect(actions.last.payload['blocking'], 2);

      final text = FileEditIntentReader.choiceText(
        'serial-lab.pkt',
        devices: 20,
        links: 19,
      );
      expect(text, contains('serial-lab.pkt'));
      expect(text.toLowerCase(), contains('edit that file'));
      expect(text.toLowerCase(), contains('create a new'));
      expect(text, contains('20 device(s)'));

      expect(
        FileEditIntentReader.choiceReplies('serial-lab.pkt'),
        ['Edit serial-lab.pkt', 'Create a new file instead'],
      );
    });
  });

  group('the file survives a restart', () {
    test('the artifact and the plan round-trip through the state', () {
      final state = SessionState()
          .withArtifact(
            'C:/out/lab.pkt',
            name: 'lab.pkt',
            updatedAt: '2026-09-26T10:00:00',
          )
          .withIntentJson('{"nodes":[]}');

      expect(state.hasArtifact, isTrue);
      final back = SessionState.decode(state.encode());
      expect(back.artifactPath, 'C:/out/lab.pkt');
      expect(back.artifactName, 'lab.pkt');
      expect(back.artifactUpdatedAt, '2026-09-26T10:00:00');
      expect(back.intentJson, '{"nodes":[]}');
    });

    test('the model is told that "it" means that file', () {
      final state = SessionState()
        .observe(
          ChatMessage(
            role: 'user',
            text: 'build me a 2 router lab',
            createdAt: '2026-09-26T10:00:00',
          ),
        )
        .withArtifact('C:/out/lab.pkt', name: 'lab.pkt');
      final block = state.promptBlock(userText: 'edit it');
      expect(block, contains('lab.pkt'));
      expect(block, contains('C:/out/lab.pkt'));
      expect(block.toLowerCase(), contains('"it"'));
      expect(block.toLowerCase(), contains('in place'));
    });

    test('an older state with no artifact still decodes', () {
      final back = SessionState.decode('{"project":"lab","focus":["R1"]}');
      expect(back.hasArtifact, isFalse);
      expect(back.artifactPath, isEmpty);
      expect(back.project, 'lab');
    });
  });

  group('nothing said two messages ago is forgotten', () {
    ChatMessage ask(String text) => ChatMessage(
          role: 'user',
          text: text,
          createdAt: '2026-09-26T10:00:00',
        );

    test('newly compacted turns are folded into the saved summary', () {
      final first = ConversationMemory.summarize([
        ask('build me a lab with 2 routers and 4 PCs'),
      ]);
      expect(first, contains('2 routers and 4 PCs'));

      // A second overflow: the newly dropped turns used to be thrown away
      // because the saved summary was replayed verbatim.
      final merged = ConversationMemory.mergeSummary(first, [
        ask('use 10.20.0.0/24 for the LANs'),
        ask('add an AAA server with user netadmin'),
      ]);
      expect(merged, contains('2 routers and 4 PCs'),
          reason: 'the original request survives');
      expect(merged, contains('10.20.0.0/24'),
          reason: 'and so does what was said since');
      expect(merged, contains('AAA server'),
          reason: 'including the most recent turns');
    });

    test('a summary written by an older build is kept, not dropped', () {
      final merged = ConversationMemory.mergeSummary(
        'Earlier: the user asked for 10 PCs and 2 routers.',
        [ask('and add a switch')],
      );
      expect(merged, contains('10 PCs and 2 routers'));
      expect(merged, contains('add a switch'));
    });

    test('the summary never crowds out the turns being typed', () {
      final history = [
        for (var i = 0; i < 8; i++)
          ask('turn $i ${String.fromCharCode(97 + i) * 3000}'),
      ];
      final plan = ContextBudget.plan(
        history: history,
        systemContext: 'you are a network engineer',
        pendingText: 'and add a switch',
        budgetTokens: 4000,
        storedSummary: ConversationMemory.summarize([ask('original request')]),
      );
      expect(plan.turnsSummarized, greaterThan(0));
      expect(plan.recentTurns, isNotEmpty,
          reason: 'the live conversation is worth more than the summary');
      expect(plan.tokensUsed, lessThanOrEqualTo(plan.windowTokens));
    });
  });
}
