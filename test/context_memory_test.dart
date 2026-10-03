import 'package:flutter_test/flutter_test.dart';

import 'package:net_builder/models/chat_message.dart';
import 'package:net_builder/services/context_budget.dart';
import 'package:net_builder/services/context_report.dart';
import 'package:net_builder/services/conversation_memory.dart';
import 'package:net_builder/services/runtime_window.dart';
import 'package:net_builder/services/session_state.dart';

/// The memory bug, pinned.
///
/// The app planned its requests against the Settings ceiling (up to 1,024k)
/// while a local runtime allocated its own window (Ollama defaults to 4096)
/// and silently discarded the front of anything bigger. Two things therefore
/// have to stay true forever:
///
///  * the request is fitted to the REAL window, never to the setting;
///  * turns that do not fit are compacted and reported, never silently cut.

ChatMessage turn(String role, String text) =>
    ChatMessage(role: role, text: text);

List<ChatMessage> convo({int turns = 8, int chars = 400}) => [
  for (var i = 0; i < turns; i++) ...[
    turn('user', 'ask $i ${'x' * chars}'),
    turn('model', 'reply $i ${'y' * chars}'),
  ],
];

RuntimeWindow get ollama4k => const RuntimeWindow(
  tokens: 4096,
  source: 'Ollama /api/ps',
  certain: true,
);

void main() {
  group('the runtime window is what the request is fitted to', () {
    test('a 1,024k setting against a 4k runtime plans for 4k', () {
      final budget = RuntimeWindow.effectiveBudget(
        configured: 1048576,
        window: ollama4k,
      );
      expect(budget, 4096,
          reason: 'the setting is a ceiling, never a promise');
    });

    test('a smaller setting still wins over a big runtime', () {
      expect(
        RuntimeWindow.effectiveBudget(
          configured: 32768,
          window: const RuntimeWindow(tokens: 131072, source: 'test'),
        ),
        32768,
      );
    });

    test('a runtime that will not say falls back conservatively when local',
        () {
      final window = RuntimeWindowProbe.resolve(baseUrl: 'http://127.0.0.1:11434/v1');
      expect(window.tokens, RuntimeWindow.conservativeLocal);
      expect(window.isAssumed, isTrue);
      expect(window.hint, isNotEmpty);
    });

    test('a remote provider is assumed to have a real window', () {
      final window = RuntimeWindowProbe.resolve(
        baseUrl: 'https://api.groq.com/openai/v1',
      );
      expect(window.tokens, greaterThanOrEqualTo(32768));
      expect(window.certain, isTrue);
    });

    test('a manual setting beats everything', () {
      final window = RuntimeWindowProbe.resolve(
        baseUrl: 'http://127.0.0.1:11434/v1',
        probed: ollama4k,
        manual: 32768,
      );
      expect(window.tokens, 32768);
      expect(window.source, 'Settings (manual)');
    });

    test('localhost spellings are recognised', () {
      for (final host in const [
        'http://127.0.0.1:11434/v1',
        'localhost:1234/v1',
        'http://[::1]:8080/v1',
      ]) {
        expect(RuntimeWindowProbe.isLocal(host), isTrue, reason: host);
      }
      expect(RuntimeWindowProbe.isLocal('https://api.openai.com/v1'), isFalse);
    });
  });

  group('Ollama/llama.cpp answers are parsed', () {
    test('llama.cpp reports the allocated window in /props', () {
      final window = RuntimeWindowProbe.parse('props', {
        'n_ctx': 8192,
        'default_generation_settings': {'n_ctx': 8192},
      }, 'local');
      expect(window?.tokens, 8192);
      expect(window?.source, 'llama.cpp /props');
      expect(window?.certain, isTrue);
    });

    test('Ollama /api/ps reports the loaded window', () {
      final window = RuntimeWindowProbe.parse('ps', {
        'models': [
          {'name': 'llama3.2:3b', 'context_length': 16384},
        ],
      }, 'llama3.2:3b');
      expect(window?.tokens, 16384);
      expect(window?.source, 'Ollama /api/ps');
    });

    test('/api/ps ignores a different model that happens to be loaded', () {
      final window = RuntimeWindowProbe.parse('ps', {
        'models': [
          {'name': 'qwen2.5:14b', 'context_length': 32768},
        ],
      }, 'llama3.2:3b');
      expect(window, isNull);
    });

    test('a baked num_ctx is honoured, and the model ceiling is reported',
        () {
      final window = RuntimeWindowProbe.parse('show', {
        'parameters': 'stop "<|eot_id|>"\nnum_ctx 32768',
        'model_info': {'llama.context_length': 131072},
      }, 'llama3.2:3b');
      expect(window?.tokens, 32768);
      expect(window?.modelMax, 131072);
    });

    test('a model ceiling without a num_ctx is reported as the ceiling, not '
        'as the window in force', () {
      final window = RuntimeWindowProbe.parse('show', {
        'model_info': {'qwen2.context_length': 131072},
      }, 'qwen2.5:3b');
      expect(window?.certain, isFalse,
          reason: 'Ollama allocates its own default unless num_ctx is baked in');
      expect(window?.modelMax, 131072);
      expect(window!.tokens, lessThanOrEqualTo(4096));
      expect(window.hint, contains('OLLAMA_CONTEXT_LENGTH'));
    });

    test('an absurd number is not believed', () {
      expect(RuntimeWindowProbe.parse('props', {'n_ctx': 12}, 'x'), isNull);
      expect(
        RuntimeWindowProbe.parse('props', {'n_ctx': 99999999}, 'x'),
        isNull,
      );
      expect(RuntimeWindowProbe.parse('props', null, 'x'), isNull);
    });
  });

  group('a small window still keeps the conversation', () {
    test('the request never exceeds the real window', () {
      final plan = ContextBudget.plan(
        history: convo(),
        systemContext: 'you are a network engineer',
        pendingText: 'what about its gateway?',
        budgetTokens: 1048576,
        runtimeWindowTokens: 4096,
        runtimeWindowSource: 'Ollama /api/ps',
      );
      expect(plan.windowTokens, 4096);
      expect(plan.budgetTokens, 1048576,
          reason: 'the setting is still reported, it is just not what fits');
      expect(plan.tokensUsed, lessThanOrEqualTo(4096));
      expect(plan.limitedByWindow, isTrue);
    });

    test('the newest turns survive even in a 4k window', () {
      final plan = ContextBudget.plan(
        history: convo(),
        systemContext: 'you are a network engineer',
        pendingText: 'what about its gateway?',
        budgetTokens: 1048576,
        runtimeWindowTokens: 4096,
      );
      expect(plan.recentTurns, isNotEmpty,
          reason: 'a runtime window must never leave the model with no history');
      expect(plan.recentTurns.last.text, contains('reply 7'));
    });

    test('turns that did not fit are summarized and the reason is recorded',
        () {
      final plan = ContextBudget.plan(
        history: convo(turns: 40),
        systemContext: 'you are a network engineer',
        pendingText: 'remind me what i asked first',
        budgetTokens: 1048576,
        runtimeWindowTokens: 4096,
      );
      expect(plan.turnsSummarized, greaterThan(0));
      expect(plan.memoryBlock, contains('ORIGINAL request'));
      expect(plan.memoryBlock, contains('ask 0'),
          reason: 'the first thing the user asked is preserved');
      expect(plan.report!.notes.join(' | '), contains('summarized'));
      expect(plan.report!.notes.join(' | '), contains('4,096'));
    });

    test('a huge system prompt is trimmed and said so, never silently cut',
        () {
      final plan = ContextBudget.plan(
        history: const [],
        systemContext: 'x' * 60000,
        pendingText: 'hello',
        budgetTokens: 1048576,
        runtimeWindowTokens: 4096,
      );
      expect(plan.tokensUsed, lessThanOrEqualTo(4096));
      expect(plan.report!.notes.join(' | '), contains('system prompt was trimmed'));
    });
  });

  group('the request report says what happened', () {
    test('it names the window, the sections and the totals', () {
      final plan = ContextBudget.plan(
        history: convo(turns: 6),
        systemContext: 'instructions here',
        networkContext: 'project: office\n- R1 g0/0=10.0.0.1/30',
        sessionState: '## Session state\n- Current problem: PC1 cannot reach SRV1',
        memories: '## Relevant memories\n- past build: office',
        pendingText: 'why?',
        budgetTokens: 8192,
        runtimeWindowTokens: 8192,
        runtimeWindowSource: 'llama.cpp /props',
        model: 'llama3.2:3b',
        provider: 'OpenAI-compatible',
      );
      final report = plan.report!;
      expect(report.model, 'llama3.2:3b');
      expect(report.runtimeWindow, 8192);
      final labels = report.sections.map((s) => s.label).toList();
      expect(labels, contains('system prompt'));
      expect(labels, contains('current message'));
      expect(labels, contains('recent conversation'));
      final text = report.toText();
      expect(text, contains('Request #0'));
      expect(text, contains('runtime window: 8,192'));
      expect(text, contains('output reserve'));
      expect(text, contains('total'));
    });

    test('it counts the sections the user asked to see separately', () {
      final plan = ContextBudget.plan(
        // Long enough that the budget genuinely has to compact something.
        history: convo(turns: 30, chars: 1200),
        systemContext: 'instructions',
        networkContext: 'project: office',
        pendingText: 'go',
        budgetTokens: 16384,
      );
      final labels = plan.report!.sections.map((s) => s.label).toList();
      expect(labels, contains('network context'));
      expect(labels, contains('conversation summary'),
          reason: 'the compacted turns have their own line');
    });

    test('the log numbers real requests and keeps them bounded', () {
      RequestLog.clear();
      for (var i = 0; i < 3; i++) {
        final plan = ContextBudget.plan(
          history: const [],
          systemContext: 's',
          pendingText: 'hi $i',
        );
        RequestLog.record(plan.report!.numbered(RequestLog.nextSequence()));
      }
      expect(RequestLog.last!.sequence, 3);
      expect(RequestLog.reports.first.sequence, 3,
          reason: 'newest first');
      expect(RequestLog.reports.length, 3);
      RequestLog.clear();
      expect(RequestLog.last, isNull);
    });
  });

  group('every block the planner built is the block that is sent', () {
    // The planner computes a session-state block and a retrieved-memory block,
    // then has to hand them back. It used to hand back neither: the blocks
    // were built, budgeted, reported as sent, and then dropped on the floor -
    // so the follow-up they exist for ("what about ITS gateway?") had nothing
    // to resolve "its" against, and a fact the app had recalled was never
    // actually sent.
    const system = 'you are a network engineer';
    const state = '## Session state\n- Current problem: PC1 cannot reach SRV1';
    const memories = '## Relevant memories\n- past build: office lab';

    test('the session state block is returned, not thrown away', () {
      final plan = ContextBudget.plan(
        history: convo(turns: 2),
        systemContext: system,
        sessionState: state,
        pendingText: 'what about its gateway?',
        budgetTokens: 8192,
      );
      expect(plan.sessionStateBlock, contains('PC1 cannot reach SRV1'));
      expect(
        plan.report!.sections.map((s) => s.label),
        contains('session state'),
      );
    });

    test('retrieved long-term memory is budgeted and returned', () {
      final plan = ContextBudget.plan(
        history: convo(turns: 2),
        systemContext: system,
        memories: memories,
        pendingText: 'why?',
        budgetTokens: 8192,
      );
      expect(plan.memoriesBlock, contains('past build: office lab'));
      expect(
        plan.report!.sections.map((s) => s.label),
        contains('retrieved memory'),
      );
    });

    test('the report charges what the blocks it lists actually cost', () {
      final plan = ContextBudget.plan(
        history: convo(turns: 4),
        systemContext: system,
        networkContext: 'project: office',
        sessionState: state,
        memories: memories,
        pendingText: 'why?',
        budgetTokens: 16384,
      );
      final report = plan.report!;
      int costOf(String label) =>
          report.sections.firstWhere((s) => s.label == label).tokens;

      expect(costOf('session state'),
          ContextBudget.estimateTokens(plan.sessionStateBlock));
      expect(costOf('retrieved memory'),
          ContextBudget.estimateTokens(plan.memoriesBlock));
      expect(costOf('network context'),
          ContextBudget.estimateTokens(plan.networkBlock));
      // Every listed section is a block the plan actually holds: a report line
      // with no block behind it is how the log started lying.
      expect(plan.sessionStateBlock, isNotEmpty);
      expect(plan.memoriesBlock, isNotEmpty);
      expect(plan.networkBlock, isNotEmpty);
    });

    test('a block that does not fit is reported, never silently dropped', () {
      final plan = ContextBudget.plan(
        history: const [],
        systemContext: 'short',
        memories: 'x' * 60000,
        pendingText: 'why?',
        budgetTokens: 4096,
      );
      expect(plan.memoriesBlock, isEmpty);
      expect(
        plan.report!.notes.join(' | '),
        contains('the retrieved memory did not fit'),
      );
      expect(
        plan.report!.sections.map((s) => s.label),
        isNot(contains('retrieved memory')),
        reason: 'a block that was not sent must not be listed as sent',
      );
    });

    test('every optional block is tried, newest value first', () {
      // All three optional blocks are offered and all three fit.
      final plan = ContextBudget.plan(
        history: convo(turns: 2),
        systemContext: system,
        networkContext: 'project: office',
        sessionState: state,
        memories: memories,
        pendingText: 'why?',
        budgetTokens: 16384,
      );
      expect(plan.networkBlock, isNotEmpty);
      expect(plan.sessionStateBlock, isNotEmpty);
      expect(plan.memoriesBlock, isNotEmpty);
      expect(plan.notes.where((n) => n.contains('did not fit')), isEmpty);
    });
  });

  group('session state (layer 2) understands follow-ups', () {
    test('TEST 1: "its" still means PC1 on the next turn', () {
      final state = SessionState();
      state.observe(turn('user', 'Check PC1.'));
      state.observe(turn('model', 'PC1 has a wrong default gateway.'));
      expect(state.focus.first, 'PC1');
      state.observe(turn('user', 'What about its gateway?'));
      final block = state.promptBlock(userText: 'What about its gateway?');
      expect(block, contains('PC1'));
      expect(block, contains('Devices in focus'));
    });

    test('TEST 2: "what about PC3?" keeps Server0 as the destination', () {
      final state = SessionState();
      state.observe(turn('user', 'Can PC2 reach Server0?'));
      expect(state.source, 'PC2');
      expect(state.destination, 'Server0');
      state.observe(turn('user', 'What about PC3?'));
      expect(state.focus.first, 'PC3');
      expect(state.destination, 'Server0',
          reason: 'the question moved, the destination did not');
      expect(state.source, 'PC3');
    });

    test('the current problem is kept across anonymous follow-ups', () {
      final state = SessionState();
      state.observe(turn('user', 'PC4 cannot reach the file server.'));
      expect(state.problem, contains('PC4 cannot reach'));
      state.observe(turn('user', 'it still does not work'));
      expect(state.problem, contains('PC4 cannot reach'),
          reason: 'an unanchored complaint does not erase the question');
    });

    test('findings come from the app, and only relevant ones are injected',
        () {
      final state = SessionState();
      state
        ..observe(turn('user', 'Check R1.'))
        ..addFinding('error: gateway 10.0.0.9 is outside 10.0.0.0/30')
        ..addFinding('warning: VLAN 20 has no access ports');
      final aboutR1 = state.promptBlock(userText: 'explain the gateway problem on R1');
      expect(aboutR1, contains('gateway 10.0.0.9'));
      final aboutSomethingElse = state.promptBlock(userText: 'write a summary');
      expect(aboutSomethingElse, isNot(contains('gateway 10.0.0.9')),
          reason: 'irrelevant state is not pasted into every prompt');
    });

    test('the last recorded change always rides along for "undo that"', () {
      final state = SessionState()
        ..observe(turn('user', 'fix the gateway on R2'))
        ..withChanges([
          {
            'actionId': 47,
            'device': 'Router1',
            'interface': 'GigabitEthernet0/0',
            'field': 'ipAddress',
            'oldValue': '10.0.0.1/24',
            'newValue': '10.0.0.254/24',
          },
        ]);
      final block = state.promptBlock(userText: 'undo that');
      expect(block, contains('10.0.0.1/24'));
      expect(block, contains('->'));
    });

    test('state survives a round trip through JSON', () {
      final state = SessionState()
        ..observe(turn('user', 'Check PC1.'))
        ..addFinding('error: something');
      final restored = SessionState.decode(state.encode());
      expect(restored.focus, state.focus);
      expect(restored.confirmedFindings, state.confirmedFindings);
      expect(SessionState.decode('{').isEmpty, isTrue,
          reason: 'a corrupt state must not crash the chat');
    });

    test('switching network resets what belonged to the old one', () {
      final state = SessionState()
        ..observe(turn('user', 'Check PC1 on the office network'))
        ..addFinding('error: bad gateway');
      final fresh = state.forNewProject('lab2.pkt');
      expect(fresh.project, 'lab2.pkt');
      expect(fresh.focus, isEmpty);
      expect(fresh.confirmedFindings, isEmpty);
    });
  });

  group('the summary preserver technical values', () {
    test('addresses, interfaces and VLANs survive verbatim', () {
      final summary = ConversationMemory.summarize([
        turn('user', 'PC1 cannot reach 192.168.1.10/24'),
        turn('model', 'Check g0/1 and VLAN 20 on SW1'),
      ]);
      expect(summary, contains('192.168.1.10/24'));
      expect(summary, contains('g0/1'));
      expect(summary, contains('VLAN 20'));
    });

    test('it is bounded, however long the conversation was', () {
      final long = [
        for (var i = 0; i < 200; i++)
          turn('user', 'request $i ${'z' * 300}'),
      ];
      final summary = ConversationMemory.summarize(long);
      expect(summary.length, lessThan(4000),
          reason: 'a summary that grows without limit crowds out the chat');
      expect(summary, contains('request 0'),
          reason: 'the original request is always kept');
      // The middle of a long session is not paraphrased into the prompt: the
      // model is told plainly that asks were left out, so it cannot assume the
      // short list it sees is the whole conversation.
      expect(summary, contains('earlier request(s) omitted'));
    });
  });
}


