import 'package:http/http.dart' as http;

import '../models/chat_message.dart';
import 'ai_provider.dart';
import 'chat_service.dart';
import 'context_budget.dart';
import 'context_report.dart';
import 'generation_control.dart';
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

  /// The user's ceiling from Settings.
  final int? contextTokens;

  /// The window the runtime really allocates, when the app could find out.
  /// This - not [contextTokens] - is what the request is actually fitted to,
  /// so a runtime that allocates 4k is never handed a 40k prompt it would
  /// silently truncate.
  final int? runtimeWindowTokens;
  final String runtimeWindowSource;
  final bool runtimeWindowAssumed;

  /// Debug logging of every assembled request (Settings developer toggle).
  final bool logRequests;

  /// The transport both provider paths use. Null in the app (each service
  /// makes its own); injectable so the whole facade - planning, assembling and
  /// sending - can be exercised without a network.
  final http.Client? client;

  ProviderChatService({
    required this.config,
    this.geminiKey = '',
    this.openaiKey = '',
    this.contextTokens,
    this.runtimeWindowTokens,
    this.runtimeWindowSource = 'configured budget',
    this.runtimeWindowAssumed = false,
    this.logRequests = false,
    this.client,
  });

  String get _providerLabel => isGemini ? 'Google Gemini' : 'OpenAI-compatible';

  /// Remember what this request carried. Called on every real send (not on the
  /// UI's preview plan), so the log is a record of traffic, not of repaints.
  void _record(ContextPlan plan) {
    final report = plan.report;
    if (report == null) return;
    // The setting is what decides whether a request is echoed to the debug
    // console; without this line the toggle in Settings did nothing.
    RequestLog.verbose = logRequests;
    RequestLog.record(report.numbered(RequestLog.nextSequence()));
  }

  ChatService get _gemini => ChatService(
    contextTokens: contextTokens,
    client: client,
  );

  /// The tool loop, when the engine offered tools.
  ///
  /// Leaving this null keeps exactly today's behaviour, so a missing sidecar
  /// can never change how chat works.
  ToolRuntime? toolRuntime;

  /// True when a tool loop is wired up at all, loaded or not.
  ///
  /// [usesTools] answers a different question - whether the engine has actually
  /// offered tools - and is what the chat branches on. This one is for the
  /// question "is this engine capable of tools", which is a different thing to
  /// ask when a sidecar is still starting.
  bool get hasToolRuntime => toolRuntime != null;

  /// True when the model can investigate the network before it answers.
  bool get usesTools => toolRuntime?.available ?? false;

  /// The tool-calling conversation as events (spec §11).
  ///
  /// [streamWithTools] is this same conversation seen as text; this shape is
  /// what a caller wants when it needs to know which tool ran and what came
  /// back, not only what was said. With no engine it degrades to a single
  /// `final` event carrying the ordinary answer.
  ///
  /// It takes the SAME context arguments as [streamWithTools] and budgets them
  /// the same way. It used to plan with the bare system prompt only, so this
  /// path silently dropped the network picture, the session state, the
  /// retrieved memories, the stored summary and every attachment - the same
  /// question answered with tools and without them were two different
  /// conversations.
  Stream<ToolLoopEvent> executeToolConversation({
    required List<ChatMessage> history,
    required String text,
    required String systemContext,
    List<ChatImage> attachments = const [],
    String networkContext = '',
    String sessionState = '',
    String memories = '',
    String storedSummary = '',
    ContextPlan? plan,
    Future<void>? abortTrigger,
    bool Function()? abortProbe,
  }) async* {
    final runtime = toolRuntime;
    final ready = runtime != null && await runtime.ensureLoaded();
    if (!ready) {
      final buffer = StringBuffer();
      await for (final piece in stream(
        history: history,
        text: text,
        systemContext: systemContext,
        attachments: attachments,
        networkContext: networkContext,
        sessionState: sessionState,
        memories: memories,
        storedSummary: storedSummary,
        abortTrigger: abortTrigger,
        abortProbe: abortProbe,
      )) {
        buffer.write(piece);
      }
      yield ToolLoopEvent(ToolLoopEventKind.finalAnswer, buffer.toString());
      return;
    }

    final effective = plan ?? planContext(
      history: history,
      text: text,
      systemContext: systemContext,
      networkContext: networkContext,
      sessionState: sessionState,
      memories: memories,
      storedSummary: storedSummary,
      attachmentCount: attachments.length,
    );
    lastPlan = effective;
    _record(effective);

    final messages = await openAiRichMessages(
      history: history,
      text: text,
      systemContext: systemContext,
      plan: effective,
      attachments: attachments,
    );
    yield* runtime
        .loop(abortTrigger: abortTrigger, abortProbe: abortProbe)
        .run(messages);
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
    String networkContext = '',
    String sessionState = '',
    String memories = '',
    String storedSummary = '',
    ContextPlan? plan,
    Future<void>? abortTrigger,
    bool Function()? abortProbe,
  }) async* {
    final runtime = toolRuntime;
    final ready = runtime != null && await runtime.ensureLoaded();
    if (!ready) {
      yield* stream(
        history: history,
        text: text,
        systemContext: systemContext,
        attachments: attachments,
        networkContext: networkContext,
        sessionState: sessionState,
        memories: memories,
        storedSummary: storedSummary,
        abortTrigger: abortTrigger,
        abortProbe: abortProbe,
      );
      return;
    }

    final effective = plan ?? planContext(
      history: history,
      text: text,
      systemContext: systemContext,
      networkContext: networkContext,
      sessionState: sessionState,
      memories: memories,
      storedSummary: storedSummary,
      attachmentCount: attachments.length,
    );
    lastPlan = effective;
    _record(effective);

    final signal = AbortSignal(abortTrigger, isAbortedNow: abortProbe);
    final messages = await openAiRichMessages(
      history: history,
      text: text,
      systemContext: systemContext,
      plan: effective,
      attachments: attachments,
    );

    await for (final event in runtime
        .loop(abortTrigger: abortTrigger, abortProbe: abortProbe)
        .run(messages)) {
      signal.throwIfAborted();
      switch (event.kind) {
        case ToolLoopEventKind.status:
          // Progress is shown; the model's reasoning is not (spec §4).
          yield '\n\n▸ ${event.text}\n';
        case ToolLoopEventKind.limit:
          yield '\n\n${event.text}\n';
        case ToolLoopEventKind.error:
          throw Exception(event.text);
        case ToolLoopEventKind.finalAnswer:
          yield event.text;
        default:
          // 'result' is progress the UI renders as activity, not answer text.
          break;
      }
    }
    signal.throwIfAborted();
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
  ///
  /// Text-only turns. [openAiRichMessages] is the same conversation for a turn
  /// that carries images.
  List<Map<String, String>> openAiMessages({
    required List<ChatMessage> history,
    required String text,
    required String systemContext,
    String networkContext = '',
    String sessionState = '',
    String memories = '',
    String storedSummary = '',
    int attachmentCount = 0,
    ContextPlan? plan,
  }) {
    final effective = plan ??
        planContext(
          history: history,
          text: text,
          systemContext: systemContext,
          networkContext: networkContext,
          sessionState: sessionState,
          memories: memories,
          storedSummary: storedSummary,
          attachmentCount: attachmentCount,
        );
    final system = _assembleSystem(systemContext, effective);
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

  /// [openAiMessages] for a turn that can carry images.
  ///
  /// The OpenAI shape for a turn with a picture is a `content` ARRAY of parts
  /// (`{'type':'text'}` / `{'type':'image_url'}`), so that is what the current
  /// user turn gets; a turn with no images keeps the plain string form, which
  /// every gateway (and every local server) accepts.
  ///
  /// Attachments belong to the CURRENT turn only. Replaying every historical
  /// screenshot would multiply the request for no benefit - the model already
  /// has the earlier conclusion in the text - and the base64 is never written
  /// to the database or to the request log: only the token cost is reported.
  ///
  /// The per-turn count and byte caps are the same ones the Gemini path uses
  /// ([ChatService.maxImagesPerTurn] / `maxRequestBytes`), so a capture cannot
  /// be too large on one provider and fine on the other.
  Future<List<Map<String, dynamic>>> openAiRichMessages({
    required List<ChatMessage> history,
    required String text,
    required String systemContext,
    List<ChatImage> attachments = const [],
    String networkContext = '',
    String sessionState = '',
    String memories = '',
    String storedSummary = '',
    int attachmentCount = 0,
    ContextPlan? plan,
  }) async {
    final effective = plan ??
        planContext(
          history: history,
          text: text,
          systemContext: systemContext,
          networkContext: networkContext,
          sessionState: sessionState,
          memories: memories,
          storedSummary: storedSummary,
          attachmentCount: attachmentCount,
        );
    final system = _assembleSystem(systemContext, effective);
    final messages = <Map<String, dynamic>>[
      if (system.trim().isNotEmpty) {'role': 'system', 'content': system},
    ];
    for (final m in effective.recentTurns) {
      if (m.isError) continue;
      if (m.text.trim().isEmpty) continue;
      messages.add({'role': _role(m), 'content': m.text});
    }

    final images = await _inlineImages(attachments);
    if (images.isEmpty) {
      if (text.trim().isNotEmpty) {
        messages.add({'role': 'user', 'content': text});
      }
      return messages;
    }

    // A turn of only screenshots still needs text: some gateways reject a part
    // array that does not start with a text part, and the model has to be told
    // what it is being asked about.
    messages.add({
      'role': 'user',
      'content': [
        {
          'type': 'text',
          'text': text.trim().isEmpty ? '(look at the attached image)' : text,
        },
        for (final image in images)
          {
            'type': 'image_url',
            'image_url': {'url': 'data:${image.mimeType};base64,${image.data}'},
          },
      ],
    });
    return messages;
  }

  /// Read the attachments off disk, honouring the shared caps.
  Future<List<({String mimeType, String data})>> _inlineImages(
    List<ChatImage> attachments,
  ) async {
    if (attachments.isEmpty) return const [];
    final reader = ChatService();
    final out = <({String mimeType, String data})>[];
    var bytes = 0;
    for (final image in attachments.take(ChatService.maxImagesPerTurn)) {
      final data = await reader.readBase64(image);
      if (data.isEmpty) continue;
      bytes += data.length;
      out.add((mimeType: image.mimeType, data: data));
    }
    if (bytes > ChatService.maxRequestBytes) {
      throw Exception(
        'Those images are too large to send in one request '
        '(${(bytes / (1024 * 1024)).round()} MB). Attach fewer or smaller ones.',
      );
    }
    return out;
  }

  /// The system prompt in the order the model reads it: instructions first,
  /// then the live network, then the structured state, then the compacted
  /// memory and the long-term memories it recalled. That order is the spec's,
  /// and it matters: an instruction the model reads after a wall of data is a
  /// weaker instruction.
  ///
  /// Every block here is one the planner actually decided to send, and the
  /// report lists the same sections, so "what did the model see" has one
  /// answer.
  String _assembleSystem(String systemContext, ContextPlan plan) {
    final parts = <String>[
      if (systemContext.trim().isNotEmpty) systemContext.trim(),
      if (plan.networkBlock.isNotEmpty) plan.networkBlock.trim(),
      if (plan.sessionStateBlock.isNotEmpty) plan.sessionStateBlock.trim(),
      if (plan.memoryBlock.isNotEmpty) plan.memoryBlock.trim(),
      if (plan.memoriesBlock.isNotEmpty) plan.memoriesBlock.trim(),
    ];
    return parts.join('\n\n');
  }

  /// The planned conversation both provider paths share.
  ContextPlan planContext({
    required List<ChatMessage> history,
    required String text,
    required String systemContext,
    String networkContext = '',
    String sessionState = '',
    String memories = '',
    String storedSummary = '',
    int attachmentCount = 0,
  }) =>
      ContextBudget.plan(
        history: history,
        systemContext: systemContext,
        pendingText: text,
        networkContext: networkContext,
        sessionState: sessionState,
        memories: memories,
        storedSummary: storedSummary,
        attachmentCount: attachmentCount,
        budgetTokens: contextTokens,
        runtimeWindowTokens: runtimeWindowTokens,
        runtimeWindowSource: runtimeWindowSource,
        runtimeWindowAssumed: runtimeWindowAssumed,
        model: config.model,
        provider: _providerLabel,
      );

  Stream<String> stream({
    required List<ChatMessage> history,
    required String text,
    required String systemContext,
    List<ChatImage> attachments = const [],
    String networkContext = '',
    String sessionState = '',
    String memories = '',
    String storedSummary = '',
    Future<void>? abortTrigger,
    bool Function()? abortProbe,
  }) {
    final plan = planContext(
      history: history,
      text: text,
      systemContext: systemContext,
      networkContext: networkContext,
      sessionState: sessionState,
      memories: memories,
      storedSummary: storedSummary,
      attachmentCount: attachments.length,
    );
    lastPlan = plan;
    _record(plan);
    if (isGemini) {
      return _gemini.stream(
        apiKey: geminiKey,
        model: config.model,
        history: plan.recentTurns,
        text: text,
        systemContext: _assembleSystem(systemContext, plan),
        attachments: attachments,
        contextTokens: contextTokens,
        plan: plan,
        systemContextIsAssembled: true,
        abortTrigger: abortTrigger,
        abortProbe: abortProbe,
      );
    }
    return _openAiTurn(
      history: history,
      text: text,
      systemContext: systemContext,
      plan: plan,
      attachments: attachments,
      abortTrigger: abortTrigger,
      abortProbe: abortProbe,
    );
  }

  /// The OpenAI-compatible turn, as a stream.
  ///
  /// The plan is built (and recorded) by the caller so the report is filled in
  /// the moment the turn is sent; the messages themselves are assembled when
  /// the stream is listened to, because reading the attachments off disk is
  /// async.
  Stream<String> _openAiTurn({
    required List<ChatMessage> history,
    required String text,
    required String systemContext,
    required ContextPlan plan,
    List<ChatImage> attachments = const [],
    Future<void>? abortTrigger,
    bool Function()? abortProbe,
  }) async* {
    final messages = await openAiRichMessages(
      history: history,
      text: text,
      systemContext: systemContext,
      plan: plan,
      attachments: attachments,
    );
    yield* OpenAiChatService(
      config: config,
      apiKey: openaiKey,
      client: client,
    ).streamMessages(
      messages,
      abortTrigger: abortTrigger,
      abortProbe: abortProbe,
    );
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
