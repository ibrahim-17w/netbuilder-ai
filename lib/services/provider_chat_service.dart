import '../models/chat_message.dart';
import 'ai_provider.dart';
import 'chat_service.dart';
import 'context_budget.dart';
import 'tool_loop.dart';
import 'tool_runtime.dart';
import 'gemini_service.dart';
import 'openai_chat_service.dart';

/// The chat's front door: it picks the configured provider and nothing else in
/// the app has to know which one is active.
///
/// Both paths share the same context budget, the same conversation memory and
/// the same streaming behaviour, so switching provider changes the brain, not
/// the product.
class ProviderChatService {
  final AiProviderConfig config;
  final String geminiKey;
  final String openaiKey;
  final int? contextTokens;

  ProviderChatService({
    required this.config,
    this.geminiKey = '',
    this.openaiKey = '',
    this.contextTokens,
  });

  ChatService get _gemini => ChatService(contextTokens: contextTokens);

  /// The tool loop, when the engine offered tools.
  ///
  /// Leaving this null keeps exactly today's behaviour, so a missing sidecar
  /// can never change how chat works.
  ToolRuntime? toolRuntime;

  /// True when the model can investigate the network before it answers.
  bool get usesTools => toolRuntime?.available ?? false;

  /// The tool-calling conversation as events (spec §11).
  ///
  /// [streamWithTools] is this same conversation seen as text; this shape is
  /// what a caller wants when it needs to know which tool ran and what came
  /// back, not only what was said. With no engine it degrades to a single
  /// `final` event carrying the ordinary answer.
  Stream<ToolLoopEvent> executeToolConversation({
    required List<ChatMessage> history,
    required String text,
    required String systemContext,
  }) async* {
    final runtime = toolRuntime;
    final ready = runtime != null && await runtime.ensureLoaded();
    if (!ready) {
      final buffer = StringBuffer();
      await for (final piece in stream(
        history: history,
        text: text,
        systemContext: systemContext,
      )) {
        buffer.write(piece);
      }
      yield ToolLoopEvent('final', buffer.toString());
      return;
    }

    final messages = <Map<String, dynamic>>[
      for (final m
          in openAiMessages(
            history: history,
            text: text,
            systemContext: systemContext,
          ))
        Map<String, dynamic>.from(m),
    ];
    yield* runtime.loop().run(messages);
  }

  /// A turn where the model may run tools first (spec §3).
  ///
  /// It drives [ToolLoop] and turns the loop's events into the same text
  /// stream the UI already renders: one short line per tool while it works,
  /// then the answer. When the engine offered no tools it falls straight
  /// through to [stream], so the fallback is the existing code path, not a
  /// copy of it.
  Stream<String> streamWithTools({
    required List<ChatMessage> history,
    required String text,
    required String systemContext,
    List<ChatImage> attachments = const [],
  }) async* {
    final runtime = toolRuntime;
    final ready = runtime != null && await runtime.ensureLoaded();
    if (!ready) {
      yield* stream(
        history: history,
        text: text,
        systemContext: systemContext,
        attachments: attachments,
      );
      return;
    }

    final messages = <Map<String, dynamic>>[
      for (final m
          in openAiMessages(
            history: history,
            text: text,
            systemContext: systemContext,
          ))
        Map<String, dynamic>.from(m),
    ];

    await for (final event in runtime.loop().run(messages)) {
      switch (event.kind) {
        case 'status':
          // Progress is shown; the model's reasoning is not (spec §4).
          yield '\n\n▸ ${event.text}\n';
        case 'limit':
          yield '\n\n${event.text}\n';
        case 'error':
          throw Exception(event.text);
        case 'final':
          yield event.text;
      }
    }
  }

  /// What the last request carried (Gemini knows the budget; the
  /// OpenAI-compatible path reports it too, from the same planner).
  ContextPlan? lastPlan;

  bool get isGemini => config.kind == AiProviderKind.gemini;

  static String _role(ChatMessage m) {
    final role = m.role.toLowerCase();
    if (role == 'model' || role == 'assistant') return 'assistant';
    if (role == 'system') return 'system';
    return 'user';
  }

  /// The OpenAI-shaped message list: system first, then the conversation.
  ///
  /// The SAME budget the Gemini path obeys decides what is sent: turns that
  /// do not fit are left out, and what they said is compacted by
  /// [ContextBudget] into the memory block appended to the system prompt.
  /// (The un-budgeted version of this method was the second reason the
  /// configured context length did not change what the chat remembered.)
  List<Map<String, String>> openAiMessages({
    required List<ChatMessage> history,
    required String text,
    required String systemContext,
    ContextPlan? plan,
  }) {
    final effective = plan ??
        ContextBudget.plan(
          history: history,
          systemContext: systemContext,
          pendingText: text,
          budgetTokens: contextTokens,
        );
    final system = effective.memoryBlock.isEmpty
        ? systemContext
        : '$systemContext\n\n${effective.memoryBlock}';
    final messages = <Map<String, String>>[
      if (system.trim().isNotEmpty) {'role': 'system', 'content': system},
    ];
    for (final m in effective.recentTurns) {
      if (m.isError) continue;
      if (m.text.trim().isEmpty) continue;
      messages.add({'role': _role(m), 'content': m.text});
    }
    if (text.trim().isNotEmpty) {
      messages.add({'role': 'user', 'content': text});
    }
    return messages;
  }

  /// The planned conversation both provider paths share.
  ContextPlan planContext({
    required List<ChatMessage> history,
    required String text,
    required String systemContext,
  }) =>
      ContextBudget.plan(
        history: history,
        systemContext: systemContext,
        pendingText: text,
        budgetTokens: contextTokens,
      );

  Stream<String> stream({
    required List<ChatMessage> history,
    required String text,
    required String systemContext,
    List<ChatImage> attachments = const [],
  }) {
    if (isGemini) {
      final client = _gemini;
      final stream = client.stream(
        apiKey: geminiKey,
        model: config.model,
        history: history,
        text: text,
        systemContext: systemContext,
        attachments: attachments,
        contextTokens: contextTokens,
      );
      return stream.map((piece) {
        lastPlan = client.lastPlan;
        return piece;
      });
    }
    final plan = planContext(
      history: history,
      text: text,
      systemContext: systemContext,
    );
    lastPlan = plan;
    final messages = openAiMessages(
      history: history,
      text: text,
      systemContext: systemContext,
      plan: plan,
    );
    return OpenAiChatService(
      config: config,
      apiKey: openaiKey,
    ).stream(messages);
  }

  /// Image attachments are stored by the Gemini-side helper; the
  /// OpenAI-compatible path sends the bytes inline, so this is a delegate and
  /// both providers accept images through the same call.
  Future<AttachResult> persistImage({
    required List<int> bytes,
    required String name,
    String mimeType = 'image/png',
  }) => ChatService().persistImage(
    bytes: bytes,
    name: name,
    mimeType: mimeType,
  );

  /// A one-shot call, used by "Test connection" and by the planner.
  Future<String> complete({
    required String text,
    String systemContext = '',
  }) async {
    if (isGemini) {
      final reply = await _gemini.send(
        apiKey: geminiKey,
        model: config.model,
        history: const [],
        text: text,
        systemContext: systemContext,
        contextTokens: contextTokens,
      );
      lastPlan = _gemini.lastPlan;
      return reply.text;
    }
    lastPlan = ContextBudget.plan(
      history: const [],
      systemContext: systemContext,
      pendingText: text,
      budgetTokens: contextTokens,
    );
    return OpenAiChatService(
      config: config,
      apiKey: openaiKey,
    ).complete(openAiMessages(
      history: const [],
      text: text,
      systemContext: systemContext,
    ));
  }

  /// A real round trip whose only job is to say whether the settings work.
  /// Returns a map with ok / message / ms so the UI can show it verbatim.
  Future<Map<String, dynamic>> testConnection() async {
    final started = DateTime.now();
    try {
      if (isGemini) {
        final err = await GeminiService().testKey(
          apiKey: geminiKey,
          model: config.model,
        );
        final ms = DateTime.now().difference(started).inMilliseconds;
        return {
          'ok': err == null,
          'ms': ms,
          'message': err ??
              'Gemini answered with `${config.model}` in $ms ms.',
        };
      }
      final bad = AiErrors.badBaseUrl(config.effectiveBaseUrl());
      if (bad.isNotEmpty) {
        return {'ok': false, 'ms': 0, 'message': bad};
      }
      final text = await OpenAiChatService(
        config: config,
        apiKey: openaiKey,
      ).complete(const [
        {'role': 'user', 'content': 'Reply with the single word: ready'},
      ]);
      final ms = DateTime.now().difference(started).inMilliseconds;
      final where = config.effectiveBaseUrl();
      return {
        'ok': text.trim().isNotEmpty,
        'ms': ms,
        'message': text.trim().isEmpty
            ? 'Connected to $where, but the model `${config.model}` returned '
                  'an empty reply.'
            : 'Connected to $where with `${config.model}` - '
                  '"${text.trim().split('\n').first}" in $ms ms.',
      };
    } catch (e) {
      return {
        'ok': false,
        'ms': DateTime.now().difference(started).inMilliseconds,
        'message': e.toString().replaceFirst('Exception: ', ''),
      };
    }
  }
}
