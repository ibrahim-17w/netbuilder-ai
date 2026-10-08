import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../widgets/chat_markdown.dart';
import '../models/chat_message.dart';
import '../models/design_brief.dart';
import '../models/environment_profile.dart';
import '../models/network_intent.dart';
import '../services/adapters/packet_tracer_adapter.dart';
import '../services/advisor_service.dart' show AdviceAnswer;
import '../services/ai_provider.dart';
import '../services/autopilot_service.dart';
import '../services/build_preflight.dart';
import '../services/build_request_reader.dart';
import '../services/casual_english.dart';
import '../services/clarification_service.dart';
import '../services/design_brief_service.dart';
import '../services/environment_profile_service.dart';
import '../services/learned_answers_service.dart';
import '../services/chat_service.dart';
import '../services/file_edit_intent.dart';
import '../services/generation_control.dart';
import '../services/layout_engine.dart';
import '../services/layout_intent.dart';
import '../screens/layout_gallery_screen.dart';
import '../screens/pkt_viewer_screen.dart';
import '../services/packet_tracer_locator.dart';
import '../services/provider_chat_service.dart';
import '../services/context_budget.dart';
import '../services/context_report.dart';
import '../services/conversation_titles.dart';
import '../services/design_library.dart';
import '../services/pkt/on_device_pkt_builder.dart';
import '../services/pkt/pkt_export_service.dart';
import '../services/pkt/template_library.dart' show PktBuildFailure;
import '../services/design_memory.dart';
import '../services/design_review.dart';
import '../services/engine_status.dart';
import '../services/memory_service.dart';
import '../services/message_understanding.dart';
import '../services/misparse_ledger.dart';
import '../services/phrasing_memory_service.dart';
import '../services/runtime_window.dart';
import '../services/scope_gate.dart';
import '../services/skill_catalog.dart';
import '../services/session_state.dart';
import '../services/tentative_language.dart';
import '../services/offline_assistant_service.dart';
import '../services/plan_repair_service.dart';
import '../services/build_artifact_service.dart';
import '../services/planner_memory_service.dart';
import '../services/planner_suggestions_service.dart';
import '../services/rule_packs_service.dart';
import '../services/settings_service.dart';
import '../services/validator_service.dart';
import '../services/gemini_model_catalog.dart';
import '../services/tool_runtime.dart';
import '../theme/app_kit.dart';
import '../theme/app_palette.dart';
import 'package:path_provider/path_provider.dart';
import '../theme/app_theme.dart';
import '../widgets/chat_activity.dart';
import '../widgets/advice_card.dart';
import '../widgets/brief_card.dart';
import '../widgets/conversation_sidebar.dart';
import '../widgets/gemini_model_picker.dart';

/// A real conversation with the model, with screenshots attached.
///
/// Design rules this screen keeps:
///
/// * The model proposes; the user approves. Every action it returns is shown
///   as a card with its own button, and nothing is typed into Packet Tracer
///   without that click. A chat window is not a reason to hand a model the
///   keyboard.
/// * Attachments come from evidence the engine already produced (`/shots`)
///   or from a file the user picks. There is no new dependency for this:
///   file_picker is already in the app.
/// * Anything the user approves that is worth reusing (a rule, a preference)
///   is written to the same memory the planner reads, so a correction given
///   in the chat actually changes the next plan.
class ChatScreen extends StatefulWidget {
  final String initialProject;
  final void Function(String project)? onOpenProject;

  /// Text the composer opens with. The capability hub uses it to send the
  /// user here with the question already written - "explain the plan",
  /// "what is wrong?" - so a button in the hub ends in a sent message
  /// instead of an empty box.
  final String initialDraft;

  const ChatScreen({
    super.key,
    this.initialProject = 'default',
    this.onOpenProject,
    this.initialDraft = '',
  });

  /// HH:mm in the device's local time, or '' when [createdAt] does not parse.
  /// One formatter for the message header and the transcript export, so a
  /// turn reads the same time on screen and in the file a user shares.
  static String _stamp(String createdAt) {
    final parsed = DateTime.tryParse(createdAt);
    if (parsed == null) return '';
    final local = parsed.toLocal();
    final hh = local.hour.toString().padLeft(2, '0');
    final mm = local.minute.toString().padLeft(2, '0');
    return '$hh:$mm';
  }

  /// The conversation as one markdown document, exactly what "Share the
  /// transcript" hands to the share sheet: who said what, in order, each
  /// turn's text verbatim (so fenced code arrives still fenced and runnable),
  /// under a header line that says when it was taken and of which chat.
  ///
  /// Pure and static so the format is testable without driving the screen or
  /// the share sheet: the transcript is a record, and a record whose shape
  /// drifts is a record nobody can cite.
  @visibleForTesting
  static String transcriptMarkdown(
    List<ChatMessage> messages, {
    String conversation = 'default',
    DateTime? exportedAt,
  }) {
    final buffer = StringBuffer();
    final when = (exportedAt ?? DateTime.now()).toIso8601String();
    buffer.writeln('# NetBuilder chat - $conversation');
    buffer.writeln();
    buffer.writeln('Exported $when - ${messages.length} messages.');
    buffer.writeln();
    for (final message in messages) {
      final who = message.isUser
          ? 'You'
          : message.isError
          ? 'App'
          : 'Assistant';
      final stamp = _stamp(message.createdAt);
      buffer.write('**$who**');
      if (stamp.isNotEmpty) buffer.write(' ($stamp)');
      buffer.writeln(':');
      buffer.writeln();
      buffer.writeln(
        message.text.trim().isEmpty ? '_(no text)_' : message.text.trim(),
      );
      buffer.writeln();
    }
    return buffer.toString();
  }

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

/// How the typed-out answer advances, and how often.
///
/// The reveal runs a timer that calls `setState` on the whole screen, so its
/// frequency is the frame budget of the streaming answer: 24 characters every
/// 12 ms was ~80 rebuilds a second, each one allocating a new `ChatMessage`
/// (which breaks the bubble's `GlobalObjectKey`) and re-running the msg
/// parse, the context budget and the validator's `NetworkInspector` read.
/// Typing out at the same speed with ~3x fewer repaints is the same
/// animation for roughly half the work.
const int kRevealChunk = 48;
const Duration kRevealTick = Duration(milliseconds: 30);

class _ChatScreenState extends State<ChatScreen> {
  final _input = TextEditingController();
  final _project = TextEditingController();
  final _scroll = ScrollController();

  /// Named so "Edit and resend" can put the caret back in the composer where
  /// the user just sent the text.
  final _composerFocus = FocusNode();
  // The provider facade: Gemini or any OpenAI-compatible endpoint, chosen
  // in Settings. Nothing else in this screen knows which one is active.
  ProviderChatService? _chat;

  /// The context ceiling in force, read from Settings on load. It is a
  /// maximum: what the request is really fitted to is [_window].
  int _contextTokens = ContextBudget.defaultContextTokens;

  /// The window the runtime really allocates (probed, or assumed for a local
  /// server, or pinned by the user). This is the number that decides how much
  /// conversation survives - see RuntimeWindow for why the setting alone
  /// cannot.
  RuntimeWindow _window = const RuntimeWindow(
    tokens: RuntimeWindow.remoteAssumed,
    source: 'not probed yet',
  );

  /// Identity of the probe behind [_window]: endpoint, model, manual override.
  /// When it changes, the probed number is stale and is re-checked.
  String _windowKey = '';

  /// Layer 2 of the memory: what this conversation is about, as data.
  SessionState _state = SessionState();

  /// The compacted summary of the turns that no longer fit (persisted per
  /// conversation, so old turns are summarized once, not once per request).
  String _storedSummary = '';

  /// Relevant long-term memories retrieved for the current turn.
  String _memories = '';

  /// The conversation list for the sidebar.
  List<Map<String, dynamic>> _conversations = const [];
  String _conversationQuery = '';

  /// The list opens by itself the first time there is width for it, and never
  /// squeezes the conversation on a narrow window (where it slides over the
  /// chat instead). [_sidebarTouched] means the user has made a choice, which
  /// is then never overridden.
  bool _sidebarOpen = false;
  bool _sidebarAutoOpened = false;
  bool _sidebarTouched = false;
  bool _inspectorOpen = false;

  /// The exact change log for this conversation (what the inspector shows and
  /// what "undo that" reads).
  List<Map<String, dynamic>> _changes = const [];

  /// The real work this turn did, for the activity panel.
  List<ActivityEntry> _activity = const [];
  bool _activityOpen = true;

  /// The text of a message that could not be answered, kept so the user
  /// can retry without typing it again.
  String? _failedText;
  String _geminiKey = '';
  String _openAiKey = '';

  /// The provider failure of the most recent online attempt ('' when the
  /// last attempt succeeded or there has been none). Kept BETWEEN turns so
  /// the header sign can say "not answering" for a while and then go quiet
  /// the moment a later call works - without it a recovered provider kept
  /// the red state until the app restarted.
  String _lastModelError = '';

  List<ChatMessage> _messages = [];
  List<ChatImage> _pending = [];
  bool _busy = false;

  /// The structured plan from the user's own words. It is what the
  /// `.pkt` builder compiles, so generation does not depend on the model.
  NetworkIntent? _lastIntent;

  /// Set when the user's latest message named one of the catalog designs and
  /// it was applied to the standing plan. Reported as a system line so the
  /// change to their design is visible rather than silent.
  ({
    NetworkDesign design,
    List<String> added,
    List<String> skipped,
  })? _appliedDesign;

  /// Whether [_lastIntent] was parsed from the LATEST user turn (rather
  /// than left over from an older one or a failed parse). The "Understood"
  /// card only renders when this is true, so the card can never show a
  /// plan the current message did not produce.
  bool _understoodOk = false;

  /// What the last tap-to-fix changed, for the card to say back: "Fixed: 40
  /// PCs". Cleared on the next send - a correction belongs to the turn that
  /// was corrected, not to every turn after it.
  String? _slotFixNote;

  /// The conversation this screen is showing. A conversation is named by the
  /// project context, which is how the sidebar lists and switches them.
  String get _conversation {
    final name = _project.text.trim();
    return name.isEmpty ? 'default' : name;
  }

  /// null = not checked yet. A false means the .pkt engine is not
  /// answering, which is the state the user needs to be told about.
  bool? _engineReachable;
  bool _engineStarting = false;

  /// Lets a streaming answer be stopped without losing what was written.
  final GenerationControl _generation = GenerationControl();
  bool _liveContext = true;
  String _target = 'packet-tracer';

  /// The capture the tools are allowed to read from, once one is
  /// scanned. Empty means there is nothing to investigate yet.
  String _capturePath = '';

  /// The .pkt this conversation produced, and when. This is what "it", "the
  /// file" and "edit that" resolve to: without it the app answered an edit
  /// request by building a second file and orphaning the first.
  String _artifactPath = '';
  String _artifactName = '';
  String _artifactUpdatedAt = '';

  /// The drawing this conversation builds with (see [LayoutRequest]). Devices
  /// are placed by the engine from this, so it is part of the build request,
  /// not a view setting. It survives an edit and a restart (read back from the
  /// artifact's note), because a redraw the user asked for must not silently
  /// revert on the next build.
  ///
  /// EMPTY means "no drawing picked yet" - and that emptiness is load
  /// bearing: a non-empty default here would be handed to autopilotPlan as
  /// if it were a choice, and the note-stamped style from a gallery pick
  /// would never be consulted. Read [_pickDrawing], not this field, at the
  /// build call.
  Map<String, dynamic> _layout = const <String, dynamic>{};

  /// The conversation's design brief: what has been settled so far, and
  /// what is still open. The brief - not the presence of a parse - decides
  /// when a build card is offered, so a describing conversation is a
  /// conversation until it is actually ready to build.
  DesignBrief _brief = const DesignBrief();

  /// The standing plan as it was before the current turn, so the offline
  /// assistant can say what changed instead of describing the lab from scratch.
  NetworkIntent? _previousIntent;

  /// The words that produced the standing plan. A follow-up that ADDS to the
  /// lab is read together with this, which is how "add an AAA server as well"
  /// keeps the 13 devices it was said about.
  String _lastBrief = '';

  /// .pkt names handed out this session, so a second build of the same lab
  /// gets `-2` instead of silently overwriting the first.
  final Set<String> _builtNames = {};

  /// The words that produced [_previousIntent]. The offline path re-plans the
  /// turn to apply learned rules, and it must merge against the SAME brief/plan
  /// pair the online path used - pairing a plan with the brief of a later turn
  /// is how the online and offline answers came to disagree about the lab.
  String _previousBrief = '';
  String _status = '';

  /// Short answers the assistant offered as taps ("Build the .pkt", "Use OSPF
  /// for routing"). Cleared as soon as the user says anything themselves.
  List<String> _quickReplies = const [];

  /// The "/" menu under the composer: what matches the token being typed
  /// (see [SkillCatalog.match]). Empty whenever the composer is not on a
  /// bare "/token".
  List<Skill> _skillMenu = const [];

  /// Plan questions this conversation has already answered (see [PlanPrompt]).
  /// One answer per disagreement: "keep the 25 PCs I listed" must not be asked
  /// again on every following turn.
  final Set<String> _answeredPrompts = <String>{};

  /// The plan question waiting on an answer, shown as a short list of options
  /// directly above the message box. A modal dialog was tried first and was
  /// wrong for this: it covers the very plan the question is about.
  PlanPrompt? _planPrompt;

  /// The in-flight progressive reveal of an offline answer, if any: the timer
  /// that advances it, the way to finish it on screen when a new turn arrives,
  /// and the way to write it down without touching a screen that is going away.
  Timer? _reveal;
  VoidCallback? _revealFinish;
  VoidCallback? _revealPersist;

  /// Whether the transcript is scrolled to the newest message. A chat that
  /// silently yanks the viewport while you are reading an old answer is worse
  /// than one that offers a button.
  bool _atBottom = true;

  /// Set when a jump-to-latest is waiting to be tapped, so the pill can say
  /// how much is waiting instead of just "down".
  int _unseen = 0;

  /// Bumped by every load, so a slower load cannot overwrite a newer one.
  int _loadEpoch = 0;

  /// Bumped by every settings read, so a slow key read cannot reinstate a
  /// configuration the user has already changed again.
  int _settingsEpoch = 0;

  /// The request report this conversation's last turn produced. The global log
  /// is not used for this: switching chats used to leave the previous
  /// conversation's context breakdown under the new one's composer.
  RequestReport? _requestReport;

  @override
  void initState() {
    super.initState();
    _project.text = widget.initialProject.trim().isEmpty
        ? 'default'
        : widget.initialProject.trim();
    if (widget.initialDraft.trim().isNotEmpty) {
      _input.text = widget.initialDraft;
    }
    _scroll.addListener(_onScroll);
    _input.addListener(_onComposerChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
    // Find out whether the .pkt engine answers before the user tries
    // anything, so an unreachable address is stated up front with a way
    // to fix it instead of being discovered inside a chat bubble.
    // The app starts the engine itself, so the banner follows that status
    // rather than believing only its own first probe.
    EngineStatus.instance.addListener(_onEngineStatus);
    // Settings is a ChangeNotifier: provider, model, key, target, context
    // budget and private mode all change it, and the open chat has to follow.
    _settings?.addListener(_onSettingsChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkEngine());
    _detectPacketTracer();
  }

  /// Whether Packet Tracer exists on this machine: null while the first
  /// probe is still running. Decides what a tap on a built `.pkt` path does
  /// (open the real app vs. the built-in viewer) and how the open card
  /// labels itself. Computed once by the locator and remembered there.
  bool? _ptInstalled;
  bool _ptDetectStarted = false;

  void _detectPacketTracer() {
    if (_ptDetectStarted || !_canOpenFiles) return;
    _ptDetectStarted = true;
    PacketTracerLocator.instance.isInstalled().then((installed) {
      if (!mounted) return;
      setState(() => _ptInstalled = installed);
    });
  }

  /// Everything a conversation owns, and nothing else.
  ///
  /// Switching, starting a new chat, clearing and deleting must all leave the
  /// screen as if that conversation had just been opened. Without this the next
  /// conversation inherited the previous one's plan, capture path, pending
  /// screenshots, change log and context report: "build it" compiled the wrong
  /// lab, and a screenshot attached in one chat was sent into the next.
  void _resetConversationState() {
    // A reveal still writing into the old transcript is finished and stored
    // first, so its answer is not lost when the screen changes underneath it.
    _revealFinish?.call();
    _reveal?.cancel();
    _reveal = null;
    _revealFinish = null;
    _revealPersist = null;
    _messages = [];
    _pending = [];
    _lastIntent = null;
    _previousIntent = null;
    _appliedDesign = null;
    _slotFixNote = null;
    _lastBrief = '';
    _previousBrief = '';
    _capturePath = '';
    _artifactPath = '';
    _artifactName = '';
    _artifactUpdatedAt = '';
    _quickReplies = const [];
    _answeredPrompts.clear();
    _planPrompt = null;
    _activity = const [];
    _activityOpen = false;
    _failedText = null;
    _memories = '';
    _storedSummary = '';
    _changes = const [];
    _state = SessionState();
    _brief = const DesignBrief();
    _requestReport = null;
    _status = '';
    _chat?.lastPlan = null;
  }

  /// What the model backend can honestly be said to be doing right now,
  /// from what this screen knows: the keys it holds, the private-mode
  /// switch, and whether the last online attempt failed. This is the state
  /// the old per-message disclaimer ("The AI model is unavailable (HTTP
  /// 503: {}), so I am answering offline") used to re-state in every
  /// offline bubble; it lives here, in one place that is always current.
  AiStatus get _aiStatus {
    final settings = _settings;
    final provider = settings?.providerConfig;
    return AiStatus.describe(
      providerLabel: provider?.label ?? 'Google Gemini',
      model: provider?.model ?? '',
      hasKey: _geminiKey.trim().isNotEmpty || _openAiKey.trim().isNotEmpty,
      privateMode: settings?.privateMode ?? false,
      lastError: _lastModelError,
    );
  }

  /// Keep the banner honest while the engine is coming up (or has just
  /// died). Busy states are ignored: "still trying" is not "unreachable".
  void _onEngineStatus() {
    final status = EngineStatus.instance;
    if (status.phase == EngineState.checking ||
        status.phase == EngineState.starting ||
        status.phase == EngineState.unknown) {
      return;
    }
    final ok = status.isUp;
    if (!mounted || ok == _engineReachable) return;
    setState(() => _engineReachable = ok);
  }

  @override
  void dispose() {
    // Write the turn down rather than drop it: an answer that was already
    // composed should not be lost because the screen closed mid-reveal. The
    // store write is safe here; a setState is not.
    _revealPersist?.call();
    _reveal?.cancel();
    // Nothing this screen started may keep running after it is gone.
    _generation.cancel();
    _settings?.removeListener(_onSettingsChanged);
    EngineStatus.instance.removeListener(_onEngineStatus);
    _scroll.removeListener(_onScroll);
    _input.removeListener(_onComposerChanged);
    _composerFocus.dispose();
    _input.dispose();
    _project.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final position = _scroll.position;
    // 80px of slack: "at the bottom" should mean what a person means by it,
    // not floating-point equality with maxScrollExtent.
    final atBottom = position.pixels >= position.maxScrollExtent - 80;
    if (atBottom != _atBottom) {
      setState(() {
        _atBottom = atBottom;
        if (atBottom) _unseen = 0;
      });
    }
  }

  /// Provider lookups are nullable on purpose: this screen must render even
  /// when it is mounted without the app's providers (a widget test booting
  /// the shell, or any future reuse). A missing provider should cost the chat
  /// its memory and settings, never its ability to draw.
  SettingsService? get _settings {
    try {
      return context.read<SettingsService>();
    } catch (_) {
      return null;
    }
  }

  MemoryService? get _memory {
    try {
      return context.read<MemoryService>();
    } catch (_) {
      return null;
    }
  }

  /// The teaching hook used when memory is not available (a widget test
  /// booting the shell, or memory not opened yet): the lesson is dropped,
  /// never thrown - learning must not break a send.
  static Future<void> _noopTeach(String key, String rewrite) async {}

  /// Rules/preferences the user taught the app, so the keyless answer
  /// evolves the same way the build screen's plan does. Journal advice the
  /// autopilot filed for review is deliberately excluded.
  Future<List<String>> _learnedRules() async {
    final mem = _memory;
    if (mem == null || !mem.ready) return const [];
    try {
      return await mem.plannerRuleTexts();
    } catch (_) {
      return const [];
    }
  }

  Future<Map<String, String>> _learnedPrefs() async {
    final mem = _memory;
    if (mem == null || !mem.ready) return const {};
    try {
      return await mem.allPrefs();
    } catch (_) {
      return const {};
    }
  }

  /// Load the conversation named by [_project].
  ///
  /// Every await here can outlive the conversation the user switched to, so
  /// the load carries the epoch it started in and gives up if a newer load
  /// began: two quick switches used to let the slower one overwrite the newer
  /// transcript.
  Future<void> _load() async {
    final epoch = ++_loadEpoch;
    final settings = _settings;
    final mem = _memory;
    if (settings != null) {
      _geminiKey = await settings.getApiKey() ?? '';
      _openAiKey = await settings.getOpenAiKey() ?? '';
      if (epoch != _loadEpoch) return;
      // Reopen the conversation the user was last in, BEFORE the runtime
      // probe and the transcript load, because both are keyed on it.
      if (widget.initialProject.trim().isEmpty &&
          settings.lastProject.isNotEmpty) {
        _project.text = settings.lastProject;
      }
      // WHAT THE RUNTIME REALLY HOLDS. Probed once per load, then the request
      // is fitted to it. Without this the app planned against the Settings
      // ceiling (up to 1,024k) while a local runtime allocated 4k and silently
      // dropped the oldest turns - the reported "remembers one message" bug.
      final window = await _probeWindow(
        settings.providerConfig.baseUrl,
        settings,
      );
      if (epoch != _loadEpoch) return;
      _window = window;
      _windowKey = _windowIdentity(settings);
    }
    // Whatever conversation this load is for, every later write uses this id
    // rather than the mutable one.
    final conversation = _conversation;
    if (mounted && settings != null && epoch == _loadEpoch) {
      setState(() {
        _target = settings.defaultTarget;
        _contextTokens = settings.contextBudget;
        _liveContext = settings.liveContext;
        _chat = _buildChat(settings);
      });
      // Ask the engine whether it is there, so the answer is known before the
      // user tries anything. No .pkt job works without it.
      _checkEngine();
    }
    await _refreshConversations();
    if (epoch != _loadEpoch) return;
    if (mem == null || !mem.ready) return;
    try {
      // Load the whole stored conversation: the context budget decides
      // what reaches the model, not this query. (A 60-message load used to be
      // one of the three caps that lost the start of a long chat.)
      final history = await mem.recentChat(
        limit: 5000,
        conversation: conversation,
      );
      if (!mounted || epoch != _loadEpoch) return;
      setState(() => _messages = history);
      _jumpToEnd();
      // The metadata is best-effort on purpose: a store that has a transcript
      // but not (yet) the newer tables must still show the transcript rather
      // than losing it to one failed lookup.
      try {
        final meta = await mem.conversationMeta(conversation);
        final changes = await mem.recentChanges(
          conversation: conversation,
          limit: 30,
        );
        if (!mounted || epoch != _loadEpoch) return;
        setState(() {
          _changes = changes;
          _storedSummary = (meta?['summary'] ?? '').toString();
          // Rebuild the structured state from the transcript, so a conversation
          // reopened after a restart still knows what it was about.
          // Deterministic replay - not a model recollection.
          _state = SessionState.decode((meta?['stateJson'] ?? '{}').toString());
          for (final message in history) {
            _state.observe(message);
          }
          _state.withChanges(changes);
          // The file this conversation produced, and the plan it came from:
          // without these, "edit it" after a restart has nothing to point at
          // and quietly builds a second file instead.
          _artifactPath = _state.artifactPath;
          _artifactName = _state.artifactName;
          _artifactUpdatedAt = _state.artifactUpdatedAt;
          final saved = _state.intentJson.trim();
          if (saved.isNotEmpty) {
            try {
              final decoded = jsonDecode(saved);
              if (decoded is Map) {
                // The saved plan is redacted, so an account it names comes
                // back without its password. The transcript still holds the
                // brief the user typed, so the withheld value is recovered
                // from there instead of being reported as a credential they
                // never gave - which left the build withheld for good.
                _lastIntent = NetworkIntent.recoverRedactedSecrets(
                  NetworkIntent.fromJson(Map<String, dynamic>.from(decoded)),
                  history
                      .where((m) => m.role == 'user')
                      .map((m) => m.text)
                      .join('\n'),
                );
                // The saved plan belongs to this conversation's last turn.
                _understoodOk = true;
              }
            } catch (_) {
              // A plan that will not decode is a plan to rebuild, not a crash.
            }
          }
          // The brief travels with the state: a reopened conversation still
          // knows what was settled and what is still open.
          final savedBrief = _state.briefJson.trim();
          if (savedBrief.isNotEmpty) {
            try {
              final decoded = jsonDecode(savedBrief);
              if (decoded is Map) {
                _brief = DesignBrief.fromJson(
                  Map<String, dynamic>.from(decoded),
                );
              }
            } catch (_) {
              // A corrupt brief is re-established by the conversation.
            }
          }
        });
      } catch (_) {}
    } catch (_) {}
  }

  /// What a window belongs to: the endpoint that serves it, the model loaded
  /// on it, and the user's own override. Any of the three changing makes the
  /// probed number wrong, and a stale window is felt exactly like the memory
  /// bug - the chat would keep planning against a window the runtime no longer
  /// allocates.
  static String _windowIdentity(SettingsService settings) =>
      '${settings.providerConfig.baseUrl}|${settings.providerConfig.model}|'
      '${settings.runtimeWindow}';

  /// Re-probe in the background when the identity changed. The user just
  /// pinned a window, or switched model; the chip must not keep showing the
  /// old one.
  void _syncWindow(SettingsService settings) {
    final key = _windowIdentity(settings);
    if (key == _windowKey) return;
    _windowKey = key;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final window = await _probeWindow(
        settings.providerConfig.baseUrl,
        settings,
      );
      if (!mounted) return;
      setState(() => _window = window);
    });
  }

  /// Ask the local runtime how much context it allocates, and fall back to a
  /// conservative assumption when it will not say. Never throws, never blocks
  /// the UI for more than the probe timeout.
  Future<RuntimeWindow> _probeWindow(
    String baseUrl,
    SettingsService settings,
  ) async {
    final manual = settings.runtimeWindow;
    if (manual > 0) {
      return RuntimeWindow(
        tokens: manual,
        source: 'Settings (manual)',
        certain: true,
      );
    }
    if (!RuntimeWindowProbe.isLocal(baseUrl)) {
      return RuntimeWindowProbe.resolve(baseUrl: baseUrl);
    }
    try {
      final probed = await RuntimeWindowProbe.probe(
        baseUrl: baseUrl,
        model: settings.providerConfig.model,
      );
      return RuntimeWindowProbe.resolve(baseUrl: baseUrl, probed: probed);
    } catch (_) {
      return RuntimeWindowProbe.resolve(baseUrl: baseUrl);
    }
  }

  /// The provider facade, carrying the runtime window so the planner fits the
  /// request to what the model will really hold.
  ProviderChatService _buildChat(SettingsService settings) => _withTools(
    ProviderChatService(
      config: settings.providerConfig,
      geminiKey: _geminiKey,
      openaiKey: _openAiKey,
      contextTokens: _contextTokens,
      runtimeWindowTokens: _window.tokens,
      runtimeWindowSource: _window.source,
      runtimeWindowAssumed: _window.isAssumed,
      logRequests: settings.contextDebug,
    ),
  );

  /// Settings changed while this chat was open: the provider, model, key,
  /// target, context budget or private mode may all be different now.
  ///
  /// The screen used to keep the facade it built at mount time, so the composer
  /// could say "OpenAI" while the transcript was still being sent to Gemini, and
  /// a new context limit was displayed but not applied.
  void _onSettingsChanged() {
    final settings = _settings;
    if (settings == null || !mounted) return;
    final epoch = ++_settingsEpoch;
    // Private mode is a promise that nothing leaves the device: an answer that
    // is already streaming has to stop now rather than finish.
    if (settings.privateMode && _busy) _cancelGeneration();
    _syncWindow(settings);
    Future<void>(() async {
      final live = _settings;
      if (live == null) return;
      // Read both keys every time, and treat a missing one as empty rather than
      // keeping the previous value: a cleared key must stop being used.
      final gemini = await live.getApiKey() ?? '';
      final openAi = await live.getOpenAiKey() ?? '';
      if (!mounted || epoch != _settingsEpoch) return;
      _applyChatConfig(live, gemini: gemini, openAi: openAi);
    });
  }

  void _applyChatConfig(
    SettingsService settings, {
    String? gemini,
    String? openAi,
  }) {
    if (!mounted) return;
    setState(() {
      if (gemini != null) _geminiKey = gemini;
      if (openAi != null) _openAiKey = openAi;
      _target = settings.defaultTarget;
      _contextTokens = settings.contextBudget;
      _liveContext = settings.liveContext;
      _chat = _buildChat(settings);
    });
  }

  /// Reload the sidebar's list (optionally filtered by the search box).
  Future<void> _refreshConversations() async {
    final mem = _memory;
    if (mem == null || !mem.ready) return;
    try {
      final list = await mem.conversations(query: _conversationQuery);
      if (!mounted) return;
      setState(() => _conversations = list);
    } catch (_) {}
  }

  void _jumpToEnd({bool animate = true}) {
    _unseen = 0;
    _atBottom = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      final target = _scroll.position.maxScrollExtent;
      if (!animate) {
        _scroll.jumpTo(target);
        return;
      }
      _scroll.animateTo(
        target,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    });
  }

  /// A new message (or a new chunk of a streaming one) arrived. If the reader
  /// is at the bottom this follows along; if they scrolled up to read, it
  /// leaves the viewport alone and counts what is waiting.
  /// True while the assistant owes an answer: busy, and the last turn is the
  /// user's. That is exactly the window where "typing" is the honest state.
  bool get _waiting => _busy && (_messages.isEmpty || _messages.last.isUser);

  void _noteNewMessage({bool animate = false}) {
    if (_atBottom) {
      _jumpToEnd(animate: animate);
      return;
    }
    if (mounted) setState(() => _unseen++);
  }

  // --- context -----------------------------------------------------------

  /// Everything the model should know before it answers, split into the parts
  /// the context builder allocates separately.
  ///
  /// The split is what makes the budget honest: a section that does not fit is
  /// dropped by name and reported, instead of silently eating the conversation.
  Future<_ContextParts> _buildContext(
    MemoryService? mem,
    String userText,
  ) async {
    var rules = <String>[];
    var prefs = <String, String>{};
    EnvironmentProfile? envProfile;
    if (mem != null && mem.ready) {
      try {
        rules = await mem.plannerRuleTexts();
        prefs = await mem.allPrefs();
        envProfile = await mem.environmentProfile();
      } catch (_) {}
    }
    final svc = _engine();
    final blockers = await svc.blockerLines(project: _project.text.trim());
    final unsupported = await svc.provenUnsupported();
    final live = _liveContext ? await _liveState(svc) : '';

    // The live run state is the network context; the app's instructions stay
    // in the system prompt where they belong (first, so they are instructions
    // rather than footnotes).
    final network = StringBuffer();
    // The remembered environment, so keyed answers answer for the same
    // person the offline advisor does instead of re-deriving from one
    // message. Stated facts still win: the profile is the fallback, and the
    // prompt says so.
    final envLine = envProfile?.summaryLine ?? '';
    if (envLine.isNotEmpty) {
      network.writeln('## User environment');
      network.writeln(
        '- remembered: $envLine (believe what the user says now over this)',
      );
    }
    if (_project.text.trim().isNotEmpty) {
      network.writeln('## Network in this conversation');
      network.writeln('- project: ${_project.text.trim()}');
    }
    if (_artifactPath.trim().isNotEmpty) {
      network.writeln(
        '- file this conversation produced: $_artifactName '
        '(at $_artifactPath)',
      );
      network.writeln(
        '  "it", "the file", "the project", "the .pkt" mean THAT file. Edit '
        'it in place unless the user asks for a new one, a copy, or a '
        'different name. Never quietly build a second file and leave the '
        'first behind.',
      );
    }
    final intent = _lastIntent;
    if (intent != null) {
      network.writeln(
        '- plan on the table (rev ${intent.revision}): '
        '${intent.nodes.length} device(s), '
        '${intent.links.length} link(s), routing ${intent.routing.isEmpty ? 'none' : intent.routing}',
      );
      final devices = intent.nodes
          .take(14)
          .map((n) => '${n.name}(${n.type})')
          .join(', ');
      network.writeln('- devices: $devices');
      final addressed = intent.addressing
          .take(14)
          .map((a) => '${a.node} ${a.iface}=${a.ipCidr}')
          .join(', ');
      if (addressed.isNotEmpty) network.writeln('- addressing: $addressed');
      if (intent.vlans.isNotEmpty) {
        network.writeln('- VLANs: ${intent.vlans.join(', ')}');
      }
    }
    if (live.trim().isNotEmpty) {
      network.writeln();
      network.writeln(live.trim());
    }

    // The findings are the app's own validator output about that plan - real
    // evidence the model can reason from and cite. They are validated for the
    // SELECTED TARGET, the same one the build gate uses, so the narrative can
    // never report a clean plan that the build card then refuses: validating
    // for the default instead let a 20+ device lab be described as fine and
    // then blocked.
    if (intent != null) {
      try {
        for (final issue in ValidatorService.validate(
          intent,
          target: _target,
        ).take(8)) {
          _state.addFinding(
            '${issue.severity}: ${issue.message}',
            confirmed: issue.severity == 'error',
          );
        }
      } catch (_) {}
    }

    return _ContextParts(
      system: ChatService.systemContext(
        target: _target,
        rulePacks: _rulePackBlock(),
        learnedRules: rules,
        preferences: prefs,
        knownBlockers: blockers,
        unsupportedCapabilities: unsupported,
        liveState: '',
      ),
      network: network.toString(),
      session: _state.promptBlock(userText: userText),
      memories: await _relevantMemories(mem, userText),
      summary: _storedSummary,
    );
  }

  /// Long-term memory (layer 3), retrieved by structured matching.
  ///
  /// Keyword/metadata matching against SQLite - the app's own past runs, the
  /// rules it learned and the corrections it was given - is enough at this
  /// size, works offline and costs nothing per turn. Embeddings would be the
  /// next step only if this measurably fails to find things.
  Future<String> _relevantMemories(MemoryService? mem, String text) async {
    if (mem == null || !mem.ready) return '';
    final words = text
        .toLowerCase()
        .split(RegExp(r'[^a-z0-9./-]+'))
        .where((w) => w.length > 3)
        .take(8)
        .toList();
    if (words.isEmpty) return '';
    try {
      final lines = <String>[];
      final builds = await mem.recentBuilds(limit: 40);
      for (final build in builds) {
        final haystack =
            '${build.projectName} ${build.instruction} ${build.target}'
                .toLowerCase();
        if (!words.any(haystack.contains)) continue;
        lines.add(
          'past build: [${build.target}] ${build.projectName} - '
          '${build.status} - ${_oneline(build.instruction)}'
          '${build.fix == null ? '' : ' (fix: ${_oneline(build.fix!)})'}',
        );
        if (lines.length >= 4) break;
      }
      final attempts = await mem.recentAttempts(limit: 40);
      for (final attempt in attempts) {
        final haystack =
            '${attempt.projectName} ${attempt.instruction} '
                    '${attempt.failureKind ?? ''}'
                .toLowerCase();
        if (!words.any(haystack.contains)) continue;
        lines.add(
          'past run: ${attempt.projectName} ${attempt.status}'
          '${attempt.failureKind == null ? '' : ' - ${attempt.failureKind}'}'
          '${attempt.correction == null ? '' : ' (corrected: ${_oneline(attempt.correction!)})'}',
        );
        if (lines.length >= 6) break;
      }
      if (lines.isEmpty) return '';
      return '## Relevant memories from this install (past sessions)\n'
          'These are real records of earlier work here. Use them when they '
          'apply; the current network data always overrides them.\n'
          '${lines.map((l) => '- $l').join('\n')}';
    } catch (_) {
      return '';
    }
  }

  static String _oneline(String text) =>
      text.replaceAll(RegExp(r'\s+'), ' ').trim();

  String _rulePackBlock() {
    try {
      return RulePacksService.packs
          .where(
            (p) => p.targets.contains('all') || p.targets.contains(_target),
          )
          .take(20)
          .map((p) => '- [${p.id}] ${p.rule}')
          .join('\n');
    } catch (_) {
      return '';
    }
  }

  /// The live picture: run counters, the last events, and what is failing.
  /// Best-effort - a stopped sidecar just means no live section.
  Future<String> _liveState(AutopilotService svc) async {
    final sb = StringBuffer();
    try {
      final summary = await svc.runSummary();
      sb.writeln('project: ${_project.text.trim()}');
      sb.writeln('ok: ${summary['ok']}  phase: ${summary['phase']}');
      sb.writeln(
        'devices done=${summary['devices_done']} '
        'skipped=${summary['devices_skipped']}  '
        'errors recovered=${summary['errors_recovered']} '
        'unrecovered=${summary['errors_unrecovered']}  '
        'red links=${summary['links_red']}  '
        'pings failed=${summary['pings_failed']}  '
        'server failures=${summary['srv_failed']}  '
        'CLI blocks=${summary['cli_context_blocks']}',
      );
      final skipped = (summary['known_blockers_skipped'] as List? ?? const []);
      if (skipped.isNotEmpty) {
        sb.writeln('steps the engine gave up on:');
        for (final item in skipped.take(6)) {
          sb.writeln('  - $item');
        }
      }
    } catch (_) {
      sb.writeln('(sidecar run summary unavailable)');
    }
    try {
      final events = await svc.events(limit: 40);
      if (events.isNotEmpty) {
        sb.writeln('recent journal events (oldest first):');
        for (final event in events) {
          final recovered = event['recovered'];
          sb.writeln(
            '  [${event['kind']}] ${event['device'] ?? ''} '
            '${event['detail'] ?? ''}'
            '${recovered == null
                ? ''
                : recovered == true
                ? ' (recovered)'
                : ' (NOT recovered)'}',
          );
        }
      }
    } catch (_) {}
    return sb.toString();
  }

  // --- sending -----------------------------------------------------------

  /// The offline engine for THIS build: the local sidecar on a
  /// desktop, or the PC running that sidecar when the app is on a
  /// phone (set it with /pc - the device has no Python of its own).
  AutopilotService _engine() =>
      AutopilotService(base: _settings?.engineBase ?? 'http://127.0.0.1:5005');

  /// Slash commands keep EVERYTHING in the chat: there is no settings
  /// screen any more, so the key, model and budget are set here.
  Future<bool> _handleCommand(String text) async {
    final lower = text.trim().toLowerCase();
    if (lower == '/help' || lower == 'help me') {
      _appendSystem(
        'Things you can do right here:\n'
        '- Attach a Packet Tracer save (.pkt) with the router button, or '
        'type `/scan C:\\path\\to\\lab.pkt` - I decrypt and audit it '
        'offline, with no Packet Tracer involved.\n'
        '- Approve, Reject or Modify each proposed fix; approved fixes are '
        'edited into a NEW .pkt and encrypted again.\n'
        '- `/build` - compile the plan into a real .pkt offline, with no\n'
        '  Packet Tracer. Works with or without an API key.\n'
        '- `/ledger` - every capture, decision, change and export on record.\n'
        '- `/key <value>` - store the Gemini key without echoing it.\n'
        '- `/model <name>` and `/budget <tokens>` - model and context size.\n'
        '- `/models` - detect what this key can use and pick, with the '
        'latest stable version recommended.\n'
        '- `/skills` - every skill this app has; or just type `/` in the '
        'box for the menu.\n'
        '- `/target <gns3|packet-tracer|cisco-ssh|aws-vpc>` - where new '
        'builds are aimed.\n'
        '- Or just ask a networking question.',
      );
      return true;
    }
    if (lower == '/skills' || lower == '/skill') {
      _appendSystem(SkillCatalog.asMarkdown());
      return true;
    }
    if (lower == '/ledger' ||
        lower == 'ledger' ||
        lower == 'show the ledger' ||
        lower == 'show the audit ledger') {
      await _showLedger();
      return true;
    }
    // The assistant's own suggestion chip says "Build the .pkt", so that exact
    // wording has to be understood: a suggestion the app cannot act on is
    // worse than no suggestion.
    if (lower == '/build' ||
        lower == '/generate' ||
        BuildRequestReader.matches(text)) {
      await _buildCurrentPlan();
      return true;
    }
    if (lower == '/scan' || lower.startsWith('/scan ')) {
      final path = lower == '/scan' ? '' : text.trim().substring(6).trim();
      if (path.isEmpty) {
        _appendSystem(
          'Usage: /scan C:\\path\\to\\lab.pkt - I decrypt and audit it '
          'offline. You can also attach the .pkt with the router button.',
        );
        return true;
      }
      await _scanPkt(path, path.split(RegExp(r'[\\/]')).last);
      return true;
    }
    if (lower.startsWith('/pc')) {
      final settings = _settings;
      final arg = text.trim().length > 3 ? text.trim().substring(3).trim() : '';
      if (settings == null) return true;
      if (arg.isEmpty || arg.toLowerCase() == 'status') {
        _appendSystem(
          'Offline engine: `${settings.engineBase}`.\n'
          'On a phone the .pkt work runs on a PC: start the sidecar '
          'there (`python pt_autopilot.py`) and point the app at it, '
          'e.g. `/pc 192.168.1.20:5005`. On an Android emulator the '
          'host is `/pc 10.0.2.2:5005`.',
        );
        return true;
      }
      await settings.setEngineBase(arg);
      final svc = _engine();
      final up = await svc.healthy;
      _appendSystem(
        up
            ? 'Engine set to `${settings.engineBase}` and it answered. '
                  'Attach a .pkt or `/scan <path>`.'
            : 'Engine set to `${settings.engineBase}`, but nothing '
                  'answered there yet. Start the sidecar on that '
                  'machine and try again.',
      );
      return true;
    }
    if (lower == '/key' || lower.startsWith('/key ')) {
      final value = lower == '/key' ? '' : text.trim().substring(5).trim();
      if (value.isEmpty) {
        _appendSystem(
          'Usage: /key <value> - stores the Gemini key without echoing it. '
          'Everything except the model works with no key.',
        );
        return true;
      }
      final settings = _settings;
      if (settings == null) return true;
      // Only report success when the key reads back, and never echo any
      // part of the key - not even its last characters.
      final ok = await settings.setApiKey(value);
      _appendSystem(
        value.isEmpty
            ? 'Key cleared. The offline planner, the .pkt tools and .pkt '
                  'generation all still work with no key.'
            : ok
            ? 'Key stored (${value.trim().length} characters) and read back, '
                  'so it will survive a restart. It is never shown again and '
                  'never written into this conversation.'
            : 'This device refused to store the key, so nothing was saved. '
                  'Try again, or carry on without one - everything except the '
                  'model works without a key.',
      );
      return true;
    }
    if (lower == '/model' || lower.startsWith('/model ')) {
      final settings = _settings;
      if (settings == null) return true;
      final name = lower == '/model' ? '' : text.trim().substring(7).trim();
      if (name.isEmpty) {
        _appendSystem(
          'Usage: /model <name> - current: `${settings.model}`. Try '
          '`/models` to detect what this key can use.',
        );
        return true;
      }
      await settings.setModel(name);
      _appendSystem('Model set to $name.');
      return true;
    }
    if (lower == '/models') {
      final settings = _settings;
      if (settings == null) return true;
      if (settings.privateMode) {
        _appendSystem(
          'Private mode is on, so the model list is not detected - that would '
          'send the key to the provider. Turn private mode off in Settings to '
          'use `/models`.',
        );
        return true;
      }
      final key = _geminiKey.trim().isNotEmpty
          ? _geminiKey
          : (await settings.getApiKey() ?? '');
      if (key.trim().isEmpty) {
        _appendSystem(
          'No Gemini key is stored, so there is nothing to detect from. '
          'Save one with `/key <value>` first.',
        );
        return true;
      }
      _appendSystem('Detecting the models this key can use...');
      try {
        final models = await GeminiModelCatalog().fetchFor(key);
        final best = GeminiModelCatalog.recommend(models);
        final lines = StringBuffer()
          ..writeln(
            '**${models.length} chat model(s) available to this '
            'key**, best first:',
          )
          ..writeln();
        for (final m in models.take(12)) {
          final mark = m.name == (best?.name ?? '')
              ? ' - **recommended (latest stable)**'
              : m.name == settings.model
              ? ' - **current**'
              : '';
          lines.writeln('- `${m.name}`$mark');
        }
        if (models.length > 12) {
          lines.writeln('- ...and ${models.length - 12} more');
        }
        _appendSystem(lines.toString());
        if (!mounted) return true;
        final chosen = await showGeminiModelPicker(
          context,
          apiKey: key,
          currentModel: settings.model,
        );
        if (chosen != null && chosen.trim().isNotEmpty) {
          await settings.setModel(chosen.trim());
          _appendSystem('Model set to ${chosen.trim()}.');
        }
      } catch (e) {
        _appendSystem(
          'Model detection failed: '
          '${e.toString().replaceFirst('Exception: ', '')}',
        );
      }
      return true;
    }
    if (lower == '/target' || lower.startsWith('/target ')) {
      final settings = _settings;
      final arg = text.trim().substring(7).trim().toLowerCase();
      if (settings == null) return true;
      if (arg.isEmpty) {
        _appendSystem(
          'Usage: /target ${SettingsService.supportedTargets.join('|')}\n'
          'Current target: `$_target`.',
        );
        return true;
      }
      if (!SettingsService.supportedTargets.contains(arg)) {
        _appendSystem(
          'Unknown target `$arg`. I have: '
          '${SettingsService.supportedTargets.join(', ')}.',
        );
        return true;
      }
      await settings.setDefaultTarget(arg);
      if (mounted) setState(() => _target = arg);
      _appendSystem(
        'Target set to `$arg`. New builds aim there, and the model is '
        'told that too.',
      );
      return true;
    }
    if (lower == '/budget' || lower.startsWith('/budget ')) {
      final settings = _settings;
      final value = lower == '/budget'
          ? null
          : int.tryParse(text.trim().substring(8).trim());
      if (settings == null) return true;
      if (value == null) {
        _appendSystem('Usage: /budget 262144  (tokens, 8k..1M)');
        return true;
      }
      await settings.setContextBudget(value);
      setState(() {
        _contextTokens = settings.contextBudget;
        _chat = _withTools(
          ProviderChatService(
            config: settings.providerConfig,
            geminiKey: _geminiKey,
            openaiKey: _openAiKey,
            contextTokens: settings.contextBudget,
          ),
        );
      });
      _appendSystem('Context budget is now $value tokens.');
      return true;
    }
    return false;
  }

  void _appendSystem(String text) {
    final turn = ChatMessage(
      role: 'model',
      text: text,
      createdAt: DateTime.now().toIso8601String(),
    );
    if (!mounted) return;
    setState(() => _messages = [..._messages, turn]);
    _jumpToEnd();
  }

  /// The "/" menu follows the composer: a leading "/token" with no space
  /// opens it, anything else closes it. A command with arguments ("/scan
  /// C:\\...\") has a space, so the menu steps aside the moment it is used.
  void _onComposerChanged() {
    if (!mounted || _busy) return;
    final matches = SkillCatalog.match(_input.text);
    if (matches.isEmpty && _skillMenu.isEmpty) return;
    setState(() => _skillMenu = matches);
    // The menu inserts a row above the composer, which can cost the field
    // its IME connection; a dropped connection is a keyboard that flickers
    // shut mid-word. The text just changed, so the caret belongs in the
    // composer - keep it there.
    if (matches.isNotEmpty) _composerFocus.requestFocus();
  }

  /// A tapped skill either runs at once (a complete, argument-free slash
  /// command) or lands in the composer to be edited and sent.
  void _useSkill(Skill skill) {
    _input.text = skill.send;
    _input.selection = TextSelection.collapsed(offset: skill.send.length);
    if (mounted) setState(() => _skillMenu = const []);
    if (skill.sendNow) {
      _send();
    } else {
      _composerFocus.requestFocus();
    }
  }

  /// The menu itself: command, what it does, and nothing it cannot do.
  Widget _skillMenuCard() {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 6),
      constraints: const BoxConstraints(maxHeight: 268),
      decoration: BoxDecoration(
        color: AppPalette.panelAlt(scheme),
        borderRadius: BorderRadius.circular(AppTheme.rMd),
        border: Border.all(color: AppPalette.hairline(scheme)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 2),
            child: Row(
              children: [
                Icon(
                  Icons.terminal_outlined,
                  size: 14,
                  color: scheme.onSurfaceVariant,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'Skills - tap one; Enter sends',
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                ),
              ],
            ),
          ),
          Flexible(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final skill in _skillMenu.take(8))
                    InkWell(
                      onTap: () => _useSkill(skill),
                      child: Semantics(
                        label: 'Skill: ${skill.title}. ${skill.detail}',
                        button: true,
                        onTap: () => _useSkill(skill),
                        child: ExcludeSemantics(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 8,
                            ),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                if (skill.command.trim().isNotEmpty)
                                  Padding(
                                    padding: const EdgeInsets.only(right: 8),
                                    child: Text(
                                      skill.command.trim(),
                                      style: TextStyle(
                                        fontFamily: 'monospace',
                                        fontSize: 12,
                                        color: scheme.primary,
                                      ),
                                    ),
                                  ),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        skill.title,
                                        style: const TextStyle(
                                          fontSize: 13,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                      Text(
                                        skill.detail,
                                        style: TextStyle(
                                          fontSize: 11.5,
                                          color: scheme.onSurfaceVariant,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _pickPkt() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        dialogTitle: 'Choose a Packet Tracer save (.pkt/.pka)',
        allowMultiple: false,
      );
      if (result == null || result.files.isEmpty) return;
      final picked = result.files.single;
      final path = picked.path ?? '';
      if (path.isEmpty) {
        _appendSystem('That picker returned no file path.');
        return;
      }
      await _scanPkt(path, picked.name);
    } catch (e) {
      _appendSystem('Could not open that file: $e');
    }
  }

  /// Give the model the engine's tools, once a capture is in play.
  ///
  /// Before a `.pkt` has been scanned there is nothing for the tools to read,
  /// so chat keeps its plain behaviour. Afterwards the model can look things
  /// up for itself: read tools answer from the engine, and any change it
  /// proposes still goes through the Approve/Reject gate (spec §8).
  ProviderChatService _withTools(ProviderChatService chat) {
    if (_capturePath.trim().isEmpty) return chat;
    chat.toolRuntime = ToolRuntime(
      config: chat.config,
      sidecarBase: _settings?.engineBase ?? 'http://127.0.0.1:5005',
      // Resolved per call, not captured here: the sidecar comes back on a new
      // port after a restart, and a tool layer still talking to the old one
      // looks like a dead chat for the rest of the session.
      baseProvider: () => _settings?.engineBase ?? 'http://127.0.0.1:5005',
      geminiKey: _geminiKey,
      openaiKey: _openAiKey,
      capturePath: _capturePath,
    );
    return chat;
  }

  /// Compile the current plan into a real .pkt, offline: no Packet Tracer,
  /// no window, no clicks. Answers in the chat either way, including when the
  /// sidecar is not running or there is no plan yet.
  /// Remember the file a build landed in, so the next turn can say "it".
  ///
  /// Written into the structured state (and from there to SQLite), because a
  /// reopened conversation must still know which file the user means - that is
  /// the whole difference between editing and orphaning a build.
  void _rememberArtifact(String path, {String? name, String? note}) {
    final trimmed = path.trim();
    if (trimmed.isEmpty) return;
    final stamp = DateTime.now().toIso8601String().substring(0, 19);
    _artifactPath = trimmed;
    _artifactName = (name?.trim().isNotEmpty ?? false)
        ? name!.trim()
        : trimmed.split(RegExp(r'[/\\]')).last;
    _artifactUpdatedAt = stamp;
    _builtNames.add(_artifactName);
    _state.withArtifact(
      trimmed,
      name: _artifactName,
      updatedAt: stamp,
      note: note,
    );
    final intent = _lastIntent;
    if (intent != null) {
      _state.withIntentJson(jsonEncode(intent.toJson(includeSecrets: false)));
    }
  }

  /// A known file named in the message ("edit netbuilder-...1236.pkt"): the
  /// request is about THAT file, however it is phrased. Empty when no known
  /// name appears.
  String _resolveNamedArtifact(String text) {
    final lower = text.toLowerCase();
    for (final f in _state.knownArtifacts) {
      if (f.name.isNotEmpty && lower.contains(f.name.toLowerCase())) {
        return f.path;
      }
    }
    return '';
  }

  /// The disambiguation card when this conversation has produced several
  /// files: which one should be changed? Each row carries what is known
  /// about that version - when it was written, and the build's own
  /// verification note - so the choice is informed, not a guess.
  ChatMessage _fileMultiChoiceTurn(
    List<({String path, String name, String at, String note})> files,
  ) {
    final b = StringBuffer(
      'This conversation has produced more than one file - tell me which '
      'one to change:\n',
    );
    for (final f in files.take(3)) {
      final bits = [
        if (f.at.isNotEmpty) 'written ${f.at.replaceFirst('T', ' ')}',
        if (f.note.isNotEmpty) f.note,
      ];
      b.writeln('- ${f.name}${bits.isEmpty ? '' : ' (${bits.join('; ')})'}');
    }
    b.write('\nReply "Edit <file name>", or say "create a new file instead".');
    return ChatMessage(
      role: 'model',
      text: b.toString(),
      createdAt: DateTime.now().toIso8601String(),
    );
  }

  /// The findings that would be baked into the .pkt: exactly the list
  /// [_compilePkt] refuses to build over, computed in one place so the build
  /// card, the chat summary and the build itself cannot disagree about whether
  /// a plan is buildable.
  List<ValidationIssue> _blockingFindings(NetworkIntent? plan) => plan == null
      ? const <ValidationIssue>[]
      : ValidatorService.validateCached(
          plan,
          target: _target,
        ).where((i) => i.blocks).toList();

  /// The build card for ONE plan version.
  ///
  /// The counts, the revision and the blocking-finding count are stamped into
  /// the payload at the moment the card is written. The card renders from the
  /// payload and its button refuses to run once the standing plan has moved
  /// on, so a build can never advertise one network and compile another.
  ChatAction _buildCardFor(NetworkIntent plan, {String mode = 'new'}) {
    final blocking = _blockingFindings(plan);
    return ChatAction(
      kind: 'pkt_generate',
      summary: 'Build a .pkt from this plan (offline, no Packet Tracer)',
      payload: <String, dynamic>{
        'revision': plan.revision,
        'project': plan.projectName,
        'devices': plan.nodes.length,
        'links': plan.links.length,
        'blocking': blocking.length,
        'mode': mode,
      },
    );
  }

  /// Why this build card must not run right now, or null when it can.
  ///
  /// The reasons are about the plan the CARD describes, never about whatever
  /// plan the screen happens to hold: the card was written for a plan version
  /// that is no longer standing, or that plan still carries findings the
  /// validator says would be baked into the file.
  ///
  /// A card with NO revision stamp is refused outright.  A card that never
  /// recorded which plan it was written for cannot claim to be the current
  /// one, and letting it run is exactly how a card that advertises nothing
  /// silently compiles whatever the conversation has become - the reported
  /// "2 device(s), 0 link(s)" card that built a 17-device lab.
  String? _buildBlockReason(ChatAction action) {
    if (action.kind != 'pkt_generate') return null;
    final plan = _lastIntent;
    if (plan == null) {
      return 'There is no plan on the table any more, so this card has '
          'nothing to compile. Describe the lab again.';
    }
    final stamped = (action.payload['revision'] ?? '').toString();
    if (stamped.isEmpty) {
      return 'Not built: this card never recorded which plan it was written '
          'for, so there is nothing to trust it against. Ask me to build the '
          'current plan and I will write a fresh card for it '
          '(rev ${plan.revision}: ${plan.nodes.length} device(s), '
          '${plan.links.length} link(s)).';
    }
    if (stamped != plan.revision) {
      return 'Not built: this card was written for plan rev $stamped, but the '
          'plan has moved on (rev ${plan.revision} - ${plan.nodes.length} '
          'device(s), ${plan.links.length} link(s)). Ask me to build the '
          'current plan instead of clicking this card.';
    }
    final blocking = _blockingFindings(plan);
    if (blocking.isNotEmpty) {
      return 'Not built: the plan still has ${blocking.length} finding(s) '
          'that would be baked into the .pkt. Fix these first (the list is in '
          'the card), then ask me to build it.';
    }
    return null;
  }

  /// The "which file did you mean?" answer, shared by the online and keyless
  /// paths so the choice is offered the same way either way.
  ChatMessage _fileChoiceTurn(
    String text, {
    String path = '',
    String name = '',
  }) {
    final resolvedPath = path.trim().isEmpty ? _artifactPath : path.trim();
    final resolvedName = name.trim().isEmpty ? _artifactName : name.trim();
    final shownName = resolvedName.isEmpty
        ? resolvedPath.split(RegExp(r'[/\\]')).last
        : resolvedName;
    final intent = _lastIntent;
    final blocking = _blockingFindings(intent).length;
    return ChatMessage(
      role: 'model',
      text: FileEditIntentReader.choiceText(
        shownName,
        devices: intent?.nodes.length ?? 0,
        links: intent?.links.length ?? 0,
        writtenAt: _artifactUpdatedAt,
      ),
      createdAt: DateTime.now().toIso8601String(),
      actions: FileEditIntentReader.choiceActions(
        path: resolvedPath,
        name: shownName,
        devices: intent?.nodes.length ?? 0,
        links: intent?.links.length ?? 0,
        revision: intent?.revision ?? '',
        project: intent?.projectName ?? '',
        blocking: blocking,
      ),
    );
  }

  /// The drawing a file was written with, from the note this app saved beside
  /// it ("layout: wide"). Empty when the file predates the note.
  String _layoutStyleOf(String path) {
    for (final file in _state.knownArtifacts) {
      if (file.path == path) {
        final style = LayoutRequest.styleFromNote(file.note);
        if (style.isNotEmpty) return style;
      }
    }
    final current = _layout['style'];
    return current is String ? current : 'tree';
  }

  /// The drawing the file on the table has, as the note every reader in the
  /// app understands. Built from what the ENGINE reported it used, not from
  /// what was asked for, so the note can never claim a picture the file does
  /// not have.
  String _layoutNote() {
    final style = '${_layout['style'] ?? 'tree'}';
    final zones = <LayoutZoneRequest>[];
    final raw = _layout['zones'];
    if (raw is List) {
      for (final zone in raw) {
        if (zone is! Map) continue;
        final names = ((zone['side'] as List?) ?? const <dynamic>[])
            .map((e) => '$e')
            .where((e) => e.trim().isNotEmpty)
            .toList();
        if (names.isEmpty) continue;
        zones.add(
          LayoutZoneRequest(names: names, edge: '${zone['edge'] ?? ''}'),
        );
      }
    }
    if (zones.isNotEmpty) {
      return LayoutRequest.noteFor(style, zones: zones);
    }
    final side = ((_layout['side'] as List?) ?? const <dynamic>[])
        .map((e) => '$e')
        .where((e) => e.trim().isNotEmpty)
        .toList();
    return LayoutRequest.noteFor(
      style,
      sideNames: side,
      sideEdge: '${_layout['sideEdge'] ?? 'left'}',
    );
  }

  /// Redraw the file this conversation produced: same network, different
  /// picture.
  ///
  /// The layout is compiled in, not applied on top: the engine places every
  /// device when it writes the file, so "make it look better" without a
  /// different drawing would rewrite the identical coordinates - which is
  /// exactly what made the app look like it was ignoring the request.
  Future<void> _redrawPkt(LayoutRequest request) async {
    final target = _artifactPath.trim().isNotEmpty
        ? _artifactPath
        : (_state.knownArtifacts.isEmpty
              ? ''
              : _state.knownArtifacts.first.path);
    final name = target.trim().isEmpty
        ? _artifactName
        : target.split(RegExp(r'[/\\]')).last;
    // What the plan will actually park, resolved against the plan itself. The
    // reader only knows the words; this is where "the servers" becomes names,
    // and an empty list is a request about devices this plan does not have.
    final parked = _lastIntent == null
        ? const <LayoutZone>[]
        : _resolveZones(request);
    if (parked.isEmpty && request.isGrouped) {
      setState(() {
        _busy = false;
        _status = '';
        _messages = [
          ..._messages,
          ChatMessage(
            role: 'model',
            text:
                'I did not move anything, because this plan has no '
                '**${_requestedDevices(request)}** to move'
                '${request.guessedSide ? ' - and you did not say which devices you meant' : ''}. '
                'Tell me what to move ("move the routers to the right") and '
                'I will redraw it.',
            createdAt: DateTime.now().toIso8601String(),
            source: AiStatus.plannerSource,
          ),
        ];
        _quickReplies = LayoutRequest.optionsFor('tree');
      });
      _jumpToEnd();
      return;
    }
    if (target.trim().isEmpty) {
      // Nothing to redraw yet: remember the choice so the build this turn
      // produces is drawn that way.
      _rememberLayout(request, parked);
      final turn = ChatMessage(
        role: 'model',
        text:
            'There is no .pkt yet, so there is nothing to redraw. I have '
            'noted it: the next file I build will use '
            '**${request.style}** — ${request.describe()}.',
        createdAt: DateTime.now().toIso8601String(),
        source: AiStatus.plannerSource,
      );
      setState(() {
        _messages = [..._messages, turn];
        _busy = false;
        _status = '';
        _quickReplies = _layoutQuickReplies(request.style);
      });
      _jumpToEnd();
      return;
    }
    setState(() {
      _busy = true;
      _status = 'Redrawing $name (${request.style})...';
    });
    _jumpToEnd();
    final edited = _lastIntent;
    final result = await _compilePkt(
      inPlacePath: target,
      expectedRevision: edited?.revision ?? '',
      layout: request.toPayload(),
    );
    if (!mounted) return;
    // Only claim what was actually asked for. The old wording asserted a
    // rationale ("you already had the default, so I redrew it as X") for any
    // non-explicit turn, including a placement request it had quietly ignored
    // - which is how a redraw that did the wrong thing read as a redraw that
    // did something.
    final why = request.explicitStyle
        ? 'Redrew the diagram as **${request.style}** — ${request.describe()}'
        : 'You did not name a drawing, so I picked a different one: '
              '**${request.style}** — ${request.describe()}';
    final guessedNote = request.guessedSide
        ? '\n\nYou said "to the side" without saying which devices, so I moved '
              'the ${request.sideKinds.join(' and ')}. Name a different set and '
              'I will redraw it.'
        : '';
    setState(() {
      _busy = false;
      _status = '';
      _messages = [
        ..._messages,
        ChatMessage(
          role: 'model',
          text:
              '$why.\n\n'
              'The network itself is untouched: the same devices, the same '
              'links, the same configuration - only where they sit on the '
              'canvas changed.$guessedNote\n\n${result.text}',
          createdAt: DateTime.now().toIso8601String(),
          actions: <ChatAction>[
            if (_lastIntent != null)
              ChatAction(
                kind: 'layout_preview',
                summary: 'Preview the drawing before opening Packet Tracer',
                payload: <String, dynamic>{'style': request.style},
              ),
            ...result.actions,
          ],
          // The engine's own work, not a model's words - said once, on the
          // turn, instead of in the prose.
          source: AiStatus.plannerSource,
        ),
      ];
      _quickReplies = _layoutQuickReplies(request.style);
    });
    _jumpToEnd();
  }

  /// Stamp the drawing the engine reported onto the plan itself, so the choice
  /// survives the next build from any screen rather than living only in this
  /// screen's memory until the app is closed.
  void _persistLayoutNoteOnIntent() {
    final intent = _lastIntent;
    if (intent == null) return;
    final cleaned = [
      for (final n in intent.notes)
        if (!n.toLowerCase().startsWith('layout:')) n,
    ];
    _lastIntent = intent.copyWith(notes: [...cleaned, _layoutNote()]);
  }

  /// The devices a request named, in the user's own words, for a message that
  /// has to explain which devices it could not find.
  String _requestedDevices(LayoutRequest request) {
    final kinds = <String>[
      if (request.sideKinds.isNotEmpty) ...request.sideKinds,
      for (final zone in request.zones) ...zone.kinds,
    ];
    final names = <String>[
      if (request.sideNames.isNotEmpty) ...request.sideNames,
      for (final zone in request.zones) ...zone.names,
    ];
    final parts = <String>[
      if (kinds.isNotEmpty) kinds.join(' and '),
      if (names.isNotEmpty) names.join(' and '),
    ];
    return parts.isEmpty ? 'such devices' : parts.join(' or ');
  }

  /// Every group the request sends to an edge, resolved to real device names.
  List<LayoutZone> _resolveZones(LayoutRequest request) {
    final intent = _lastIntent;
    if (intent == null) return const <LayoutZone>[];
    if (request.zones.isNotEmpty) {
      return <LayoutZone>[
        for (final zone in request.zones)
          LayoutZone(
            resolveSideNames(intent, kinds: zone.kinds, names: zone.names),
            edge: zone.edge,
          ),
      ].where((z) => z.side.isNotEmpty).toList();
    }
    final single = resolveSideNames(
      intent,
      kinds: request.sideKinds,
      names: request.sideNames,
    );
    return single.isEmpty
        ? const <LayoutZone>[]
        : <LayoutZone>[LayoutZone(single, edge: request.sideEdge)];
  }

  /// Keep the chosen drawing on the plan itself, not only in this screen's
  /// memory. Without this the choice survived the next edit but not the next
  /// rebuild from another screen, and the lab silently went back to site trees.
  void _rememberLayout(LayoutRequest request, List<LayoutZone> parked) {
    final intent = _lastIntent;
    _layout = <String, dynamic>{
      ...request.toPayload(),
      if (parked.length == 1) ...<String, dynamic>{
        'side': parked.first.side,
        'sideEdge': parked.first.edge,
      },
      if (parked.length > 1)
        'zones': <Map<String, dynamic>>[
          for (final zone in parked)
            <String, dynamic>{'side': zone.side, 'edge': zone.edge},
        ],
    };
    if (intent == null) return;
    final cleaned = [
      for (final n in intent.notes)
        if (!n.toLowerCase().startsWith('layout:')) n,
    ];
    _lastIntent = intent.copyWith(
      notes: <String>[
        ...cleaned,
        if (parked.isEmpty)
          LayoutRequest.noteFor(request.style)
        else
          LayoutRequest.noteFor(
            request.style,
            zones: <LayoutZoneRequest>[
              for (final zone in parked)
                LayoutZoneRequest(names: zone.side, edge: zone.edge),
            ],
          ),
      ],
    );
  }

  /// The chips under a redraw answer: the other drawings, plus a way to SEE
  /// this one. A drawing nobody can look at before opening Packet Tracer is
  /// the other half of "it just returned the normal one".
  List<String> _layoutQuickReplies(String style) => <String>[
    'Preview this drawing',
    ...LayoutRequest.optionsFor(style),
  ];

  /// "Preview this drawing", "show me the layout", "let me see the picture" -
  /// a request to LOOK at the drawing rather than change it. Read before the
  /// layout reader, which would otherwise treat "drawing" as a vague redraw
  /// request and cycle the style.
  static final RegExp _wantsPreview = RegExp(
    r'^\s*(?:please\s+)?'
    r'(?:show|see|view|look|open|draw|give|let)\s+(?:me\s+)?'
    r'(?:a\s+|the\s+|this\s+|its\s+)*'
    r'(?:preview|picture|image|screen\s*shot|layout|drawing|diagram|topology)'
    r'.*\s*$|'
    r'^\s*(?:preview|show)\s+(?:this|the|me)\b.*$|'
    r'^\s*preview\s+this\s+drawing\s*$',
    caseSensitive: false,
  );

  bool get _isPreviewRequest => _wantsPreview.hasMatch(_input.text.trim());

  /// Opens the gallery on the drawing the plan would be built with, seeded
  /// with the style this conversation is on. Returns false when there is no
  /// plan, because a preview of nothing is worse than saying so.
  Future<bool> _previewLayout(String style) async {
    final intent = _lastIntent;
    if (intent == null || intent.nodes.isEmpty) return false;
    final parked = ((_layout['side'] as List?) ?? const <dynamic>[])
        .map((e) => '$e')
        .where((e) => e.trim().isNotEmpty)
        .toList();
    final current = style.isEmpty ? '${_layout['style'] ?? 'tree'}' : style;
    final picked = await LayoutGalleryScreen.show(
      context,
      intent: intent,
      currentStyle: LayoutRequest.allStyles.contains(current)
          ? current
          : 'tree',
      side: parked.isEmpty ? const <String>['server'] : parked,
    );
    // The pick is the choice: whatever style came back from the gallery is
    // what the next build draws. Dropping the return value here used to
    // mean a preview pick silently changed nothing - the user picked a
    // design and the build ignored them.
    if (picked == null || picked == current) return true;
    final parkedForPick = picked == 'grouped'
        ? (parked.isEmpty ? const <String>['server'] : parked)
        : <String>[];
    setState(() {
      _layout = {
        'style': picked,
        if (parkedForPick.isNotEmpty) 'side': parkedForPick,
      };
    });
    _persistLayoutNoteOnIntent();
    if (!mounted) return true;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        content: Text('Layout set to "$picked" - the next build uses it.'),
        duration: const Duration(seconds: 2),
      ),
    );
    return true;
  }

  /// Rewrite the file this conversation produced, keeping a backup.
  ///
  /// This is what "edit it" runs: the same plan, written over the same file,
  /// with the sidecar keeping the previous generation beside it.
  Future<void> _editPktInPlace(String path) async {
    if (!mounted) return;
    final knownName = _state.knownArtifacts
        .where((f) => f.path == path)
        .map((f) => f.name)
        .firstWhere((n) => n.trim().isNotEmpty, orElse: () => '');
    // The file being rewritten, named. An answer that says only "editing the
    // file" leaves the user guessing which one, and the point of an edit is
    // that it lands in a file they already have.
    final target = knownName.isNotEmpty
        ? knownName
        : (_artifactName.isEmpty
              ? path.split(RegExp(r'[/\\]')).last
              : _artifactName);
    setState(() {
      _busy = true;
      _status = 'Editing $target (a backup is kept)...';
    });
    _jumpToEnd();
    // What this edit changes, in the user's own terms, taken from the plan
    // before and after: an edit that landed nothing must not look like one
    // that did, and the user asked for a focused change to a network they
    // already have.
    final edited = _lastIntent;
    final delta = edited == null
        ? ''
        : NetworkIntent.planChangeSummary(_previousIntent, edited);
    // An in-place rewrite destroys the file the user already has, so it is
    // held to the same rule as a build card: the plan it writes must be the
    // plan the request was about.  Compiling a plan that had since moved on
    // would overwrite their file with something they never asked for.
    final result = await _compilePkt(
      inPlacePath: path,
      expectedRevision: edited?.revision ?? '',
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      _status = '';
      _messages = [
        ..._messages,
        ChatMessage(
          role: 'model',
          text: delta.isEmpty
              ? 'Editing the file in place: `$target`. The lab itself is '
                    'unchanged.\n\n${result.text}'
              : 'Editing the file in place: `$target`. Change applied: '
                    '$delta.\n\n${result.text}',
          createdAt: DateTime.now().toIso8601String(),
          actions: result.actions,
          source: AiStatus.plannerSource,
        ),
      ];
    });
    _jumpToEnd();
    final mem = _memory;
    if (mem != null && mem.ready) {
      try {
        await mem.setSessionState(_conversation, _state.encode());
      } catch (_) {}
    }
  }

  /// True when two paths are the same file, however they are written.
  static bool _samePath(String a, String b) =>
      a.trim().replaceAll('\\', '/').toLowerCase() ==
      b.trim().replaceAll('\\', '/').toLowerCase();

  /// Build the standing plan from a place that has no card of its own (a slash
  /// command, the Capture sheet). The card is minted for the plan that stands
  /// right now, so the same version check and the same blocking-finding check
  /// run - the quick paths do not bypass the gate.
  Future<void> _buildCurrentPlan() async {
    final plan = _lastIntent;
    if (plan == null || plan.nodes.isEmpty) {
      _appendSystem(
        'There is no plan to compile yet. Describe the network you want first '
        '- for example "2 routers, 3 switches, 12 PCs and OSPF" - and then '
        'build it. No API key is needed for this.',
      );
      return;
    }
    await _buildPktFromPlan(_buildCardFor(plan));
  }

  /// Compile the plan a build card was written for.
  ///
  /// The card carries the revision it was created against, and the build
  /// refuses when the standing plan is no longer that revision: clicking an
  /// old card must never quietly compile a different (or smaller) network
  /// than the card described.
  Future<void> _buildPktFromPlan(ChatAction action) async {
    if (!mounted) return;
    final blocked = _buildBlockReason(action);
    if (blocked != null) {
      setState(() {
        _busy = false;
        _messages = [
          ..._messages,
          ChatMessage(
            role: 'model',
            text: blocked,
            createdAt: DateTime.now().toIso8601String(),
          ),
        ];
      });
      _jumpToEnd();
      return;
    }
    setState(() {
      _busy = true;
      _status = 'Compiling the plan into a .pkt (no Packet Tracer)...';
    });
    _jumpToEnd();
    final result = await _compilePkt(
      expectedRevision: (action.payload['revision'] ?? '').toString(),
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      _status = '';
      _messages = [
        ..._messages,
        ChatMessage(
          role: 'model',
          text: result.text,
          createdAt: DateTime.now().toIso8601String(),
          actions: result.actions,
          source: AiStatus.plannerSource,
        ),
      ];
    });
    _jumpToEnd();
  }

  /// The work behind [_buildPktFromPlan]: returns what to say and which
  /// follow-up actions the answer earned. Never throws - a failure is a
  /// message, because a stack trace in the chat helps nobody.
  ///
  /// [inPlace] rewrites the file this conversation already produced (keeping a
  /// timestamped backup first) instead of writing a new one, which is the
  /// difference between "edit it" and "make me another".
  Future<({String text, List<ChatAction> actions})> _compilePkt({
    String inPlacePath = '',
    String expectedRevision = '',
    Map<String, dynamic>? layout,
  }) async {
    // The drawing this conversation is using. Sticky on purpose: a user who
    // asked for a compact diagram does not want the next edit to silently go
    // back to the default one. EMPTY is not a choice - an empty map handed
    // downstream reads as "the user picked tree", and a note-stamped gallery
    // pick upstream would never be consulted.
    final drawing = layout ?? (_layout.isEmpty ? null : _layout);
    final intent = _lastIntent;
    if (intent == null) {
      // An edit with no plan behind it is the one case where saying nothing
      // about the file is worse than saying the awkward thing: the file is
      // there, this conversation just does not remember what is inside it, and
      // overwriting it from a guess would throw away devices, links and
      // addressing nobody can see from here.
      final name = inPlacePath.trim().isEmpty
          ? ''
          : inPlacePath.split(RegExp(r'[/\\]')).last;
      if (name.isNotEmpty) {
        return (
          text: FileEditIntentReader.noPlanText(name),
          actions: const <ChatAction>[],
        );
      }
      return (
        text:
            'There is no plan to compile yet.\n\n'
            'Describe the network you want - for example "2 routers, 3 '
            'switches, 12 PCs and OSPF" - and then build it. No API key is '
            'needed for this.',
        actions: const <ChatAction>[],
      );
    }
    // The card the user pressed names the plan version it was written for.
    // Compiling a different one would mean the file, the counts on the card
    // and the plan on the table all describe different networks.
    if (expectedRevision.isNotEmpty && expectedRevision != intent.revision) {
      return (
        text:
            'I did not build this. The card you pressed was written for plan '
            'rev $expectedRevision; the plan on the table is now rev '
            '${intent.revision} (${intent.nodes.length} device(s), '
            '${intent.links.length} link(s)). Ask me to build the current '
            'plan and I will compile exactly that - I will not compile a '
            'different network than the card promised.',
        actions: const <ChatAction>[],
      );
    }
    // A plan the validator rejects must not be compiled on its way to a real
    // device: the file would carry the same mistakes the report describes, and
    // the report is exactly what a test is judged on.
    final blocking = _blockingFindings(intent);
    if (blocking.isNotEmpty) {
      final errors = blocking
          .where((i) => i.severity == 'error')
          .map((i) => '- ${i.message}')
          .toList();
      final warnings = blocking
          .where((i) => i.severity == 'warning')
          .map((i) => '- ${i.message}')
          .toList();
      return (
        text:
            'I did not build this yet: the plan still has '
            '${blocking.length} finding(s) that would be baked into the .pkt.\n\n'
            '${errors.isEmpty ? '' : '**Errors**\n${errors.join('\n')}\n\n'}'
            '${warnings.isEmpty ? '' : '**Warnings**\n${warnings.join('\n')}\n\n'}'
            'Fix these in the brief (or in the network inspector) and ask me to '
            'build it again.',
        actions: const <ChatAction>[],
      );
    }
    final svc = _engine();
    // One health answer per compile: probing twice would make a phone with
    // no engine wait twice for a timeout that answers the same way.
    final engineHealthy = await svc.healthy;
    // A phone builds with the bundled template library by default (see
    // SettingsService.preferOnDevicePkt); a desktop keeps the engine first,
    // because its builds also drive the Packet Tracer window. When the
    // on-device route cannot run here - no library and no seed - an engine
    // that IS answering still gets the job, and one that is not gets a word
    // in below.
    final preferOnDevice =
        _settings?.preferOnDevicePkt ?? SettingsService.isMobile;
    if (preferOnDevice || !engineHealthy) {
      final onDevice = await _compilePktOnDevice(
        intent: intent,
        drawing: drawing,
        engineHealthy: engineHealthy,
      );
      if (onDevice != null) return onDevice;
      if (!engineHealthy) {
        return (
          text: AutopilotService.startHint,
          actions: const <ChatAction>[],
        );
      }
    }
    try {
      final plan = PacketTracerAdapter.autopilotPlan(intent, layout: drawing);
      final preflight = BuildPreflight.lines(intent: intent, target: _target);
      // An in-place edit writes over the file the user already has; the
      // sidecar keeps a timestamped backup of what was there before.
      final editing = inPlacePath.trim().isNotEmpty;
      final res = await svc.pktGenerate(
        plan,
        filename: editing
            ? inPlacePath.split(RegExp(r'[\\/]')).last
            // THE FILE IS NAMED FOR THE NETWORK, not for the clock: a name
            // the user picked (or the brief's own words) is findable in a
            // folder full of labs; a timestamp is not.
            : BuildArtifactService.networkFileName(
                plan: intent,
                brief: _lastBrief,
                taken: {
                  for (final a in _state.knownArtifacts) a.name,
                  ..._builtNames,
                },
              ),
        project: _project.text.trim(),
        replace: editing,
      );
      final path = '${res['path'] ?? ''}';
      if (path.isEmpty) {
        return (
          text:
              'The generator ran but reported no file, so nothing was '
              'written.',
          actions: const <ChatAction>[],
        );
      }
      // The tool layer may now read this capture, and the model may be asked
      // about it.
      _capturePath = path;
      // Verification evidence: read the file we just wrote back through the
      // engine's audit BEFORE claiming the build matches the plan. No audit
      // collected means the message below says "unverified", not "done".
      Map<String, dynamic>? audit;
      try {
        final a = await svc.pktAudit(path, project: _project.text.trim());
        if (a['devices'] is List) audit = a;
      } catch (_) {
        // Not collected; the build message must say so.
      }
      final check = audit == null
          ? null
          : BuildPreflight.compare(
              intent: intent,
              audit: audit,
              builtDevices: (res['devices'] as List?) ?? const [],
            );
      final backup = '${res['backupName'] ?? res['backupPath'] ?? ''}';
      final warnings = (res['warnings'] as List?) ?? const [];
      final body = StringBuffer();
      if (editing) {
        body
          ..writeln('**Preflight (checked before compiling)**')
          ..writeln()
          ..writeln(preflight.join('\n'))
          ..writeln()
          ..writeln('**Edited `$_artifactName` in place.**')
          ..writeln()
          ..writeln('- File: `$path`')
          ..writeln(
            '- Devices: ${res['deviceCount'] ?? '?'}, '
            'links: ${res['linkCount'] ?? '?'}',
          );
        body.writeln(
          backup.isEmpty
              ? '- The previous build was replaced. Nothing else was created.'
              : '- Your previous build is kept as `$backup`, so this edit is '
                    'reversible.',
        );
        _writeVerification(body, check);
      } else {
        body
          ..writeln('**Preflight (checked before compiling)**')
          ..writeln()
          ..writeln(preflight.join('\n'))
          ..writeln()
          ..writeln('**Built a .pkt from your plan.**')
          ..writeln()
          ..writeln('- File: `$path`')
          ..writeln(
            '- Devices: ${res['deviceCount'] ?? '?'}, '
            'links: ${res['linkCount'] ?? '?'}',
          );
        _writeVerification(body, check);
      }
      // Every build is read back and judged against the design rubric, and only
      // the ones that hold together are remembered. This runs after the file
      // exists, so what is reviewed is exactly what was built - not an
      // intention that may not have survived the build.
      final review = DesignReviewer.review(intent);
      DesignMemory.recordBuild(plan: intent, review: review);
      _writeDesignReview(body, intent, review);

      // The engine reports the drawing it actually used, so what the app
      // tells the user matches the file rather than the request.
      final applied = res['layout'];
      if (applied is Map) {
        _layout = Map<String, dynamic>.from(applied);
      }
      if (warnings.isEmpty) {
        body.writeln('- Warnings: none');
      } else {
        body.writeln('- Warnings:');
        for (final w in warnings) {
          body.writeln('    - $w');
        }
      }
      body
        ..writeln()
        ..writeln(
          editing
              ? 'That ran offline - no Packet Tracer, no screen - writing over '
                    'the file you already had. Ask me to change something else '
                    'and it edits the same file again.'
              : 'This ran offline - no Packet Tracer and no screen. The '
                    'plan came from your own words, so the file is the same '
                    'whether or not an API key is set: a key changes how I '
                    'explain things, not what gets built. Open it in Packet '
                    'Tracer to check it, or analyze it here.',
        )
        ..writeln();
      // The file is what "it" means from now on, so the app remembers it -
      // with the verification note, so a later "which file?" question can
      // say what is known about each version.
      _rememberArtifact(
        path,
        note:
            '${check == null ? 'verification not collected' : (check.verified ? 'build verified against the file' : 'verification found differences')}'
            '; ${_layoutNote()}',
      );
      _persistLayoutNoteOnIntent();
      return (
        text: body.toString(),
        actions: [
          // OPEN IN PACKET TRACER, on the machines that can: the file goes
          // to the OS and the .pkt association hands it to Packet Tracer.
          // On a phone there is no Packet Tracer - the topology preview is
          // the way to see the network there, so no open action. The label
          // follows detection: where Packet Tracer was not found the card
          // says what it actually does (the built-in viewer) instead of
          // promising an application that is not there.
          if (_canOpenFiles)
            ChatAction(
              kind: 'pkt_open',
              summary: _ptInstalled == false
                  ? 'View the network (no Packet Tracer found)'
                  : 'Open in Packet Tracer',
              payload: {'path': path, 'name': path.split(RegExp(r'[\\/]')).last},
            ),
          ChatAction(
            kind: 'pkt_scan',
            summary: 'Analyze the generated file',
            payload: {'path': path, 'name': path.split(RegExp(r'[\\/]')).last},
          ),
        ],
      );
    } catch (e) {
      return (
        text:
            'I could not build the .pkt: '
            '${e.toString().replaceFirst('Exception: ', '')}',
        actions: const <ChatAction>[],
      );
    }
  }

  /// The phone's route: compile the plan with the bundled template library,
  /// entirely on this device. Same plan JSON as the engine build, same
  /// report sections in the answer, no PC anywhere in the loop.
  ///
  /// Returns null when this device cannot build at all (no bundled library
  /// and no imported seed) but the engine can take the build instead, so the
  /// caller falls through. When the engine is down too, the returned text
  /// names both ways out.
  Future<({String text, List<ChatAction> actions})?> _compilePktOnDevice({
    required NetworkIntent intent,
    required Map<String, dynamic>? drawing,
    required bool engineHealthy,
  }) async {
    final plan = PacketTracerAdapter.autopilotPlan(intent, layout: drawing);
    final preflight = BuildPreflight.lines(intent: intent, target: _target);
    // THE FILE IS NAMED FOR THE NETWORK (small-office-ospf.pkt), and the
    // name is checked against the destination folder on disk, so a second
    // build of a different lab never clobbers the first. On-device this is
    // a local check; the engine route dedupes against the session's own
    // artifacts instead.
    var filename = BuildArtifactService.networkFileName(
      plan: intent,
      brief: _lastBrief,
      taken: {
        ..._builtNames,
        for (final a in _state.knownArtifacts) a.name,
      },
    );
    // WHERE THE FILE GOES. The folder chosen in Settings is the destination
    // when it is one the app can really write to; otherwise the lab is built
    // into app-private storage and offered for export, because a file saved
    // where nobody can browse it is not saved at all.  Resolved INSIDE the
    // try: a folder that cannot even be probed is a destination problem, and
    // must never be able to fail the build.
    // The type is spelled out because the initialiser's `dir: null` infers
    // the record field as `Null`, which is not assignable from the
    // `Directory? dir` that resolveFolder returns - the whole function then
    // fails to compile and the `folder.dir` reads below look dead.
    ({Directory? dir, String why}) folder = (
      dir: null,
      why: 'no folder has been set yet',
    );
    try {
      folder = await PktExportService.resolveFolder(_settings?.outputDir ?? '');
      // The folder is real: names already ON DISK count as taken too.
      if (folder.dir != null) {
        final onDisk = folder.dir!
            .listSync()
            .whereType<File>()
            .map((f) => f.uri.pathSegments.last.toLowerCase())
            .toSet();
        var n = 2;
        while (onDisk.contains(filename.toLowerCase())) {
          final base = filename.substring(0, filename.length - 4);
          filename = '$base-$n.pkt';
          n += 1;
        }
      }
      final built = await OnDevicePktBuilder.buildFromPlan(
        plan: plan,
        appDir: getApplicationDocumentsDirectory,
        filename: filename,
        project: _project.text.trim(),
        outDir: folder.dir == null ? null : () async => folder.dir!,
      );
      if (built == null) {
        return (
          text:
              'That plan has no devices in it, so there is nothing to '
              'build.',
          actions: const <ChatAction>[],
        );
      }
      final path = built.file.path;
      _capturePath = path;
      final report = built.report ?? const <String, dynamic>{};
      // Verification evidence: read the file we just wrote back through the
      // on-device audit BEFORE claiming the build matches the plan. No
      // audit collected means the message below says "unverified", not
      // "done".
      Map<String, dynamic>? audit;
      try {
        final a = OnDevicePktBuilder.auditReport(
          built.file.readAsBytesSync(),
          path: path,
          project: _project.text.trim(),
        );
        if (a['devices'] is List) audit = a;
      } catch (_) {
        // Not collected; the build message must say so.
      }
      final check = audit == null
          ? null
          : BuildPreflight.compare(
              intent: intent,
              audit: audit,
              builtDevices: (report['devices'] as List?) ?? const [],
            );
      final warnings = (report['warnings'] as List?) ?? built.warnings;
      final body = StringBuffer()
        ..writeln('**Preflight (checked before compiling)**')
        ..writeln()
        ..writeln(preflight.join('\n'))
        ..writeln()
        ..writeln('**Built a .pkt on this device.**')
        ..writeln()
        ..writeln('- File: `$path`')
        ..writeln(
          '- Devices: ${report['deviceCount'] ?? '?'}, '
          'links: ${report['linkCount'] ?? '?'}',
        )
        ..writeln(
          '- Compiled on this device: no Packet Tracer, no PC, nothing '
          'left it.',
        );
      _writeVerification(body, check);
      // Same design review the engine build records, so a phone-built lab
      // is held to the same rubric and remembered the same way.
      final review = DesignReviewer.review(intent);
      DesignMemory.recordBuild(plan: intent, review: review);
      _writeDesignReview(body, intent, review);
      // The build reports the drawing it actually used, so the next edit
      // keeps it.
      final applied = report['layout'];
      if (applied is Map && applied.isNotEmpty) {
        _layout = Map<String, dynamic>.from(applied);
      }
      if (warnings.isEmpty) {
        body.writeln('- Warnings: none');
      } else {
        body.writeln('- Warnings:');
        for (final w in warnings) {
          body.writeln('    - $w');
        }
      }
      body
        ..writeln()
        ..writeln(
          'The plan came from your own words, so the file is the same '
          'whether or not an API key is set. Open it in Packet Tracer on a '
          'PC to check it, or analyze it here.',
        )
        ..writeln()
        ..writeln(
          folder.dir == null
              ? 'This device has no folder set for .pkt files '
                  '(${folder.why}), so the lab was written into the app\'s own '
                  'storage. Tap "Save it to a folder" below to put a copy '
                  'somewhere you can browse, or set a folder in Settings - '
                  'Tools - Settings.'
              : 'It is in the folder you chose, next to your other labs.',
        )
        ..writeln();
      _rememberArtifact(
        path,
        note:
            'built on-device; ${check == null ? 'verification not collected' : (check.verified ? 'build verified against the file' : 'verification found differences')}'
            '; ${_layoutNote()}',
      );
      _persistLayoutNoteOnIntent();
      return (
        text: body.toString(),
        actions: [
          if (_canOpenFiles && folder.dir != null)
            ChatAction(
              kind: 'pkt_open',
              summary: _ptInstalled == false
                  ? 'View the network (no Packet Tracer found)'
                  : 'Open in Packet Tracer',
              payload: {'path': path, 'name': filename},
            ),
          ChatAction(
            kind: 'pkt_scan',
            summary: 'Analyze the generated file',
            payload: {'path': path, 'name': filename},
          ),
          if (folder.dir == null)
            ChatAction(
              kind: 'pkt_export',
              summary: 'Save it to a folder you can browse',
              payload: {'path': path, 'name': filename},
            ),
        ],
      );
    } on OnDeviceBuildError catch (e) {
      if (engineHealthy) return null;
      return (
        text:
            '${e.message}\n\nThe engine is not answering either, so this '
            'build needs one of the two: import a seed .pkt in Tools, or '
            'start the engine on your PC and set its address.',
        actions: const <ChatAction>[],
      );
    } on PktBuildFailure catch (e) {
      if (engineHealthy) return null;
      return (
        text: 'I could not build the .pkt on this device: ${e.message}',
        actions: const <ChatAction>[],
      );
    } catch (e) {
      return (
        text: 'The on-device build failed: $e',
        actions: const <ChatAction>[],
      );
    }
  }

  /// Decrypt and audit a .pkt completely offline: no Packet Tracer, no
  /// window, no clicks. Findings come back as Approve/Reject cards.
  Future<void> _scanPkt(String path, String name) async {
    final ask = ChatMessage(
      role: 'user',
      text: 'Analyze this capture offline: $name',
      createdAt: DateTime.now().toIso8601String(),
    );
    setState(() {
      _messages = [..._messages, ask];
      _busy = true;
      _status = 'Decrypting and auditing $name (no Packet Tracer)...';
    });
    _jumpToEnd();
    try {
      final svc = _engine();
      // Say plainly what the file is before trying to read it: a .pcap
      // gets an explanation, not a decode error.
      final ident = await svc.pktIdentify(path);
      if (ident['isPkt'] != true) {
        if (!mounted) return;
        setState(() {
          _busy = false;
          _status = '';
        });
        _appendSystem('${ident['message'] ?? 'That file is not a .pkt save.'}');
        return;
      }
      // From here on the model may investigate this capture with the
      // engine's read-only tools (spec §2/§3).
      _capturePath = path;
      final report = await svc.pktAudit(path, project: _project.text.trim());
      final turn = ChatMessage(
        role: 'model',
        text: _auditText(report, name, path),
        actions: _fixActions(report, path, name),
        createdAt: DateTime.now().toIso8601String(),
      );
      if (!mounted) return;
      setState(() {
        _busy = false;
        _status = '';
        _messages = [..._messages, turn];
      });
      _jumpToEnd();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _status =
            'Could not read that capture: '
            '${e.toString().replaceFirst('Exception: ', '')}';
      });
    }
  }

  String _auditText(Map<String, dynamic> report, String name, String path) {
    final devices = (report['devices'] as List?) ?? const [];
    final findings = <Map<String, dynamic>>[];
    for (final d in devices) {
      for (final f in (((d as Map)['findings'] as List?) ?? const [])) {
        findings.add(Map<String, dynamic>.from(f as Map));
      }
    }
    final high = findings
        .where((f) => '${f['severity']}'.toLowerCase() == 'high')
        .length;
    final b = StringBuffer()
      ..writeln(
        '**Capture decrypted and audited offline.** Packet Tracer '
        'was not opened.',
      )
      ..writeln()
      ..writeln('- File: `$name`')
      ..writeln('- Path: `$path`')
      ..writeln(
        '- Devices: ${devices.length}, links: ${_linkCount(report)}, '
        'findings: ${findings.length} ($high high)',
      )
      ..writeln(
        '- Key: the save container was decrypted with the built-in '
        'Packet Tracer codec; no credential of yours is involved or shown.',
      );
    if (findings.isEmpty) {
      b
        ..writeln()
        ..writeln(
          'Nothing to fix: the saved configuration matches the '
          'topology. Ask me anything about it.',
        );
    } else {
      b
        ..writeln()
        ..writeln(
          '**Prioritised findings** - approve a fix below and I edit '
          'the save and encrypt it back:',
        );
      for (final f in findings.take(12)) {
        b.writeln(
          '- [${f['severity'] ?? 'info'}] ${f['device'] ?? ''} - '
          '${f['text'] ?? ''}',
        );
      }
    }
    return b.toString();
  }

  /// How many cables the audit found, however the engine reported them.
  ///
  /// The deep audit answers with `summary.links` and a top-level `links`
  /// array; the summary-only reply has `linkCount`. Reading just the last one
  /// printed "links: ?" on a file whose cables had all been counted, which
  /// reads as a failed decode of a file that decoded perfectly.
  static String _linkCount(Map<String, dynamic> report) {
    final summary = report['summary'];
    if (summary is Map) {
      final n = summary['links'];
      if (n is num) return '${n.toInt()}';
    }
    final direct = report['linkCount'];
    if (direct is num) return '${direct.toInt()}';
    final rows = report['links'];
    if (rows is List) return '${rows.length}';
    return '?';
  }

  List<ChatAction> _fixActions(
    Map<String, dynamic> report,
    String path,
    String name,
  ) {
    final out = <ChatAction>[];
    for (final d in ((report['devices'] as List?) ?? const [])) {
      final dev = (((d as Map)['name'] ?? '')).toString();
      for (final f in (((d['findings'] as List?) ?? const []))) {
        final m = Map<String, dynamic>.from(f as Map);
        final cli = ((m['fix_cli'] as List?) ?? const [])
            .map((e) => e.toString())
            .toList();
        if (cli.isEmpty) continue;
        out.add(
          ChatAction(
            kind: 'pkt_fix',
            summary: '${m['text'] ?? 'fix'}   ->   ${cli.join(' ; ')}',
            payload: {
              'path': path,
              'name': name,
              'device': dev,
              'id': '${m['id'] ?? ''}',
              'severity': '${m['severity'] ?? ''}',
              'text': '${m['text'] ?? ''}',
              'fix_cli': cli,
            },
          ),
        );
      }
    }
    return out;
  }

  /// Write the plan-vs-file verification block from the collected audit.
  ///
  /// "Agrees with the plan" is only ever printed from a real audit of the
  /// written file; without one the line says so in plain words.
  /// Says what applying a design did to the plan, and what the plan is
  /// worth afterwards.
  ///
  /// The re-score is the point. Offering a design without showing that it
  /// made the design better is just a suggestion; showing 62/100 becoming
  /// 88/100 is evidence, and it is the same review the build path uses, so
  /// the two numbers are always comparable.
  void _reportAppliedDesign(
    ({
      NetworkDesign design,
      List<String> added,
      List<String> skipped,
    }) applied,
  ) {
    final before = DesignReviewer.review(_previousIntent ?? _lastIntent!);
    final after = DesignReviewer.review(_lastIntent!);
    final body = StringBuffer()
      ..writeln(
        '**Applied the ${applied.design.name} design.** '
        '${applied.design.blurb}',
      );
    if (applied.added.isNotEmpty) {
      body.writeln('- Added: ${applied.added.join(', ')}.');
    }
    if (applied.skipped.isNotEmpty) {
      body.writeln('- Already there: ${applied.skipped.join(', ')}.');
    }
    final delta = after.score - before.score;
    body.writeln(
      '- Design quality: ${before.score}/100 -> ${after.score}/100'
      '${delta == 0 ? '' : ' (${delta > 0 ? '+' : ''}$delta)'}'
      ' - ${after.verdict}.',
    );
    if (after.headline.isNotEmpty) body.writeln('- ${after.headline}');
    // Everything the design added is now in the standing plan, so the next
    // build compiles it and the preview draws it.
    body.writeln('- Say "build it" to compile this into a .pkt.');
    _appendSystem(body.toString().trimRight());
  }

  void _writeVerification(
    StringBuffer body,
    ({bool verified, List<String> lines})? check,
  ) {
    if (check == null) {
      body.writeln(
        '- Verification: not collected - the file was written but could not '
        'be audited, so the plan-vs-file match is unverified.',
      );
      return;
    }
    for (final line in check.lines) {
      body.writeln(line);
    }
  }

  /// The design review of what was just built, written for a person rather
  /// than for a report.
  ///
  /// It says three things in order: how the design held up, what is worth
  /// fixing (worst first), and - when the review found something - which
  /// named designs would address it. The third part is the point of the
  /// whole loop: the review does not just criticise, it points at the designs
  /// in the library that fix what it complained about, and the ones that score
  /// well get remembered for next time.
  void _writeDesignReview(
    StringBuffer body,
    NetworkIntent intent,
    DesignReview review,
  ) {
    body
      ..writeln()
      ..writeln('**Design review: ${review.score}/100 (${review.verdict})**')
      ..writeln()
      ..writeln(review.headline);
    if (review.findings.isEmpty) {
      body
        ..writeln()
        ..writeln(
          'Nothing to fix. ${review.strengths.join('. ')}.',
        );
      return;
    }
    body
      ..writeln()
      ..writeln('- What holds up: ${review.strengths.join('; ')}.');
    for (final f in review.findings.take(4)) {
      final label = switch (f.severity) {
        DesignSeverity.fault => 'Wrong',
        DesignSeverity.gap => 'Missing',
        DesignSeverity.note => 'Worth knowing',
      };
      body.writeln(
        '- $label (${f.area}): ${f.message}'
        '${f.fix.isEmpty ? '' : ' ${f.fix}'}',
      );
    }
    if (review.findings.length > 4) {
      body.writeln('- And ${review.findings.length - 4} more.');
    }

    // The designs that would actually address what the review complained
    // about, best fit first - and what this shape scored last time it was
    // built, which is how a design gets better rather than merely repeated.
    final alternatives = DesignLibrary.suggestionsForReview(intent, review);
    if (alternatives.isEmpty) return;
    final remembered = DesignMemory.recallFor(intent);
    body
      ..writeln()
      ..writeln('Designs that would address this:');
    for (final s in alternatives.take(3)) {
      body.writeln(
        '- **${s.design.name}** - ${s.design.blurb}'
        '${s.reasons.isEmpty ? '' : ' (${s.reasons.join('; ')})'}',
      );
    }
    body.writeln(
      'Ask me to rebuild with one of those and I will apply it to the plan.',
    );
    if (remembered != null) {
      body.writeln(
        'This shape scored ${remembered.bestScore}/100 the last '
        '${remembered.builds == 1 ? 'time' : '${remembered.builds} times'} you '
        'built it.',
      );
    }
  }

  Future<String> _applyPktFix(ChatAction action) async {
    final payload = action.payload;
    final fix = <String, dynamic>{
      'id': payload['id'],
      'device': payload['device'],
      'severity': payload['severity'],
      'text': payload['text'],
      'fix_cli': payload['fix_cli'],
    };
    final res = await _engine().pktApplyFixes({
      'path': payload['path'],
      'fixes': [fix],
      'outName': payload['name'],
      'project': _project.text.trim(),
    });
    // Spec §9: do not take the fix at its word. Re-audit the file that came
    // out and check the finding is actually gone before saying it is fixed.
    final verdict = await _verifyRepair(
      beforePath: '${payload['path'] ?? ''}',
      afterPath: '${res['path'] ?? ''}',
      findingId: '${fix['id'] ?? ''}',
    );
    final turn = ChatMessage(
      role: 'model',
      text: '${_appliedText(res, fix)}$verdict',
      actions: [
        ChatAction(
          kind: 'pkt_undo',
          summary: 'Undo this change (restores the save from before it)',
          payload: {'entryId': '${res['entryId'] ?? ''}'},
        ),
        const ChatAction(
          kind: 'ledger',
          summary: 'Show the audit ledger',
          payload: {},
        ),
      ],
      createdAt: DateTime.now().toIso8601String(),
    );
    if (mounted) {
      setState(() => _messages = [..._messages, turn]);
      _jumpToEnd();
    }
    return 'Applied and re-encrypted. The original save was not modified.';
  }

  String _appliedText(Map<String, dynamic> res, Map<String, dynamic> fix) {
    final sha = '${res['sha256'] ?? ''}';
    final b = StringBuffer()
      ..writeln('**Approved fix applied, and the save was encrypted back.**')
      ..writeln()
      ..writeln('- Device: ${fix['device']}')
      ..writeln('- Result: `${res['name'] ?? ''}`')
      ..writeln('- Path: `${res['path'] ?? ''}`')
      ..writeln(
        '- SHA-256: `${sha.length >= 16 ? sha.substring(0, 16) : sha}...`',
      )
      ..writeln('- Bytes: ${res['bytes'] ?? '?'}')
      ..writeln();
    for (final d in ((res['diffs'] as List?) ?? const [])) {
      final m = Map<String, dynamic>.from(d as Map);
      b.writeln('**${m['device']}**');
      for (final c in ((m['changes'] as List?) ?? const [])) {
        final row = Map<String, dynamic>.from(c as Map);
        b.writeln('- ${row['section']}: `${row['command']}`');
      }
      for (final line in ((m['diff'] as List?) ?? const [])) {
        b.writeln('    $line');
      }
      b.writeln();
    }
    b.writeln(
      'The original save was NOT modified - this is a new file. '
      'Open it in Packet Tracer, or Undo to go back.',
    );
    return b.toString();
  }

  /// Put a file this conversation built into a folder the user can browse.
  ///
  /// On Android a lab built on-device lives in app-private storage that no
  /// file manager can open, so this hands the real bytes to the system's own
  /// save dialog: the user picks the folder and the file lands there. The
  /// app's copy is left alone - the manifest next to it still identifies the
  /// file as one this app generated.
  Future<String> _exportBuiltPkt(ChatAction action) async {
    final path = '${action.payload['path'] ?? ''}'.trim();
    if (path.isEmpty) return 'That card has no file to save.';
    final file = File(path);
    if (!file.existsSync()) {
      return 'That file is gone from this device ($path).';
    }
    final companion = File('$path.netbuilder.json');
    final result = await PktExportService.saveToChosenFolder(
      file,
      companion: companion.existsSync() ? companion : null,
    );
    if (result.cancelled && result.prompted && result.path.isEmpty) {
      return result.message;
    }
    if (!mounted) return result.message;
    _appendSystem('**Saved.** ${result.message}');
    return result.message;
  }

  /// Re-audit the result and report what the engine actually finds now.
  ///
  /// A failure here never invalidates the applied change: it is reported as
  /// applied-but-unverified rather than silently assumed to have worked.
  Future<String> _verifyRepair({
    required String beforePath,
    required String afterPath,
    required String findingId,
  }) async {
    if (beforePath.trim().isEmpty || afterPath.trim().isEmpty) return '';
    try {
      final engine = _engine();
      final project = _project.text.trim();
      final before = await engine.pktAudit(beforePath, project: project);
      final after = await engine.pktAudit(afterPath, project: project);
      final result = await engine.verifyRepair(
        before: before,
        after: after,
        fixes: [
          {'id': findingId},
        ],
      );
      final summary = '${result['summary'] ?? ''}'.trim();
      if (summary.isEmpty) return '';
      return '\n---\n**Verification:** $summary\n';
    } catch (e) {
      return '\n---\n**Verification:** could not be run ('
          '${e.toString().replaceFirst('Exception: ', '')}). '
          'The change is applied but unverified.\n';
    }
  }

  Future<String> _undoPktFix(ChatAction action) async {
    final res = await _engine().pktUndo(
      entryId: '${action.payload['entryId'] ?? ''}',
    );
    _appendSystem(
      '**Undone.** The save from before that change was restored as '
      '`${res['name'] ?? ''}` (`${res['path'] ?? ''}`). The fixed file is '
      'untouched, so you can compare them.',
    );
    return 'Restored the previous state.';
  }

  Future<String> _showLedger() async {
    final report = await _engine().pktLedger();
    final b = StringBuffer()
      ..writeln('**Audit ledger**')
      ..writeln()
      ..writeln('- Entries: ${report['count'] ?? 0}')
      ..writeln('- Applied changes: ${report['applied'] ?? 0}')
      ..writeln('- Rejections: ${report['rejected'] ?? 0}')
      ..writeln('- Undos: ${report['undone'] ?? 0}')
      ..writeln('- Ledger file: `${report['path'] ?? ''}`')
      ..writeln();
    for (final e in ((report['entries'] as List?) ?? const [])) {
      final row = Map<String, dynamic>.from(e as Map);
      b.writeln(
        '- ${row['at']}  **${row['event']}**  '
        '${row['device'] ?? row['id'] ?? ''}  ${row['decision'] ?? ''}',
      );
    }
    b.writeln();
    b.writeln(
      'Keys are never recorded - a secret command is stored as '
      '•••••••• in the ledger.',
    );
    _appendSystem(b.toString());
    return 'Ledger shown.';
  }

  /// MODIFY: edit the proposed commands before approving them. The edited
  /// list goes through exactly the same gate as an untouched approval.
  Future<void> _modifyAction(
    int messageIndex,
    int actionIndex,
    ChatAction action,
  ) async {
    final controller = TextEditingController(
      text: (action.payload['fix_cli'] as List?)?.join('\n') ?? '',
    );
    final edited = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Modify this fix'),
        content: SizedBox(
          width: 520,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${action.payload['device']}: ${action.payload['text'] ?? ''}',
                style: const TextStyle(fontSize: 12),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: controller,
                minLines: 3,
                maxLines: 10,
                decoration: const InputDecoration(
                  labelText: 'Commands, one per line',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: const Text('Approve edited'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (edited == null) return;
    final cli = edited
        .split(RegExp(r'[\n;]'))
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList();
    if (cli.isEmpty) {
      _appendSystem('Nothing left to apply after the edit.');
      return;
    }
    final payload = Map<String, dynamic>.from(action.payload)
      ..['fix_cli'] = cli;
    setState(() => _busy = true);
    String outcome;
    try {
      outcome = await _applyPktFix(
        ChatAction(
          kind: 'pkt_fix',
          summary: 'edited: ${cli.join(' ; ')}',
          payload: payload,
        ),
      );
    } catch (e) {
      outcome = 'Not applied: ${e.toString().replaceFirst('Exception: ', '')}';
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _status = outcome;
      final message = _messages[messageIndex];
      _messages = [..._messages];
      _messages[messageIndex] = message.copyWith(
        executed: [...message.executed, actionIndex.toString()],
      );
    });
  }

  Future<void> _rejectAction(
    int messageIndex,
    int actionIndex,
    ChatAction action,
  ) async {
    setState(() => _busy = true);
    String outcome;
    try {
      await _engine().pktReject(
        action.payload,
        capture: '${action.payload['name'] ?? ''}',
      );
      outcome =
          'Rejected. Nothing was written, exported or changed - the '
          'decision is on the ledger.';
    } catch (e) {
      outcome =
          'Could not record the rejection: '
          '${e.toString().replaceFirst('Exception: ', '')}';
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _status = outcome;
      final message = _messages[messageIndex];
      _messages = [..._messages];
      _messages[messageIndex] = message.copyWith(
        executed: [...message.executed, actionIndex.toString()],
      );
    });
  }

  /// Put a message on the clipboard verbatim, and say so.
  ///
  /// The confirmation is part of the feature: without it a tap looks like it
  /// did nothing. A clipboard that refuses is reported rather than swallowed.
  Future<void> _copyMessage(String text) async {
    if (text.trim().isEmpty) return;
    try {
      await Clipboard.setData(ClipboardData(text: text));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Copied'), duration: Duration(seconds: 1)),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not copy: $e')));
    }
  }

  /// Stop the answer as it streams. Whatever was already written stays; the
  /// turn simply stops growing.
  void _cancelGeneration() {
    if (!_busy) return;
    _generation.cancel();
    setState(() {
      _busy = false;
      _status = 'Stopped.';
    });
  }

  /// The plan question still waiting on an answer, if any.
  PlanPrompt? _nextPlanPrompt(NetworkIntent? plan) {
    if (plan == null) return null;
    for (final prompt in plan.prompts) {
      if (prompt.options.isEmpty) continue;
      if (_answeredPrompts.contains(prompt.id)) continue;
      return prompt;
    }
    return null;
  }

  /// Answer the plan's own question from the option list above the message box.
  ///
  /// A brief that contradicts itself - "a corporate network for 40 users ...
  /// 15 PCs ... 10 PCs" - states a headcount of 40 and then lists 25 PCs. The
  /// app used to settle that silently in its own favour: 25 PCs were built and
  /// the audit said "nothing to fix", so the 15 missing ones were never
  /// mentioned. The chosen option travels as a normal message, so "add 15 more
  /// PCs" is planned by the same code a typed request uses; "keep what I
  /// listed" only closes the question.
  Future<void> _answerPlanPrompt(
    PlanPrompt prompt,
    PlanPromptOption option,
  ) async {
    setState(() {
      _answeredPrompts.add(prompt.id);
      _planPrompt = null;
    });
    final reply = option.reply.trim();
    if (reply.isEmpty || !mounted) return;
    await _sendQuickReply(reply);
  }

  /// The question as a short list of options: title, the reason, then one chip
  /// per answer, the recommended one first and ticked.
  Widget _planPromptCard(PlanPrompt prompt, ColorScheme scheme) {
    return AppPanel(
      dense: true,
      tone: AppTone.accent,
      filled: true,
      icon: Icons.help_outline,
      title: prompt.title,
      children: [
        Text(
          prompt.message,
          style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: AppTheme.s8),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final option in prompt.options)
              ActionChip(
                avatar: option.recommended
                    ? const Icon(Icons.check_circle_outline, size: 15)
                    : null,
                label: Text(
                  option.label,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: option.recommended
                        ? FontWeight.w600
                        : FontWeight.w400,
                  ),
                ),
                onPressed: _busy
                    ? null
                    : () => _answerPlanPrompt(prompt, option),
              ),
          ],
        ),
      ],
    );
  }

  /// One tap on one of the assistant's own suggestions. It is sent as a real
  /// message, so it lands in the transcript and the offline path answers it
  /// exactly as if it had been typed.
  ///
  /// A suggestion tapped WHILE A TURN IS STILL RUNNING is not dropped and does
  /// not eat the draft: the text the user already typed is theirs, so the box
  /// is left exactly as it is (overwriting it is what used to destroy a
  /// half-written message), the chips stay up, and the suggestion lands in the
  /// composer so the tap has a visible result and the turn it belongs to goes
  /// out as soon as the current one ends. `_send()` is the single place that
  /// decides a turn may start, so an early return there leaves the draft
  /// sitting in the box rather than throwing it away.
  Future<void> _sendQuickReply(String text) async {
    if (_busy) {
      if (_input.text.trim().isEmpty) {
        setState(() => _input.text = text);
      }
      return;
    }
    setState(() {
      _input.text = text;
      _quickReplies = const [];
    });
    await _send();
  }

  Future<void> _send() async {
    var text = _input.text.trim();
    // ENTER WHILE THE "/" MENU IS OPEN completes the command. The menu only
    // shows for a bare "/token" (a space closes it), so this expands a
    // partial command and can never swallow a real message with arguments.
    if (_skillMenu.isNotEmpty && !text.contains(' ')) {
      final exact = SkillCatalog.all.any((s) => s.command.trim() == text);
      if (!exact) {
        final replacement = _skillMenu.first.send.trim();
        if (replacement.isEmpty) return;
        _input.text = replacement;
        text = replacement;
      }
    }
    if ((text.isEmpty && _pending.isEmpty) || _busy) return;
    // A typed message replaces the suggestions; they were an answer to the
    // turn before this one. It also ends any reveal still in flight - the
    // previous answer appears at once rather than growing under the new turn.
    _revealFinish?.call();
    if (mounted && (_quickReplies.isNotEmpty || _skillMenu.isNotEmpty)) {
      setState(() {
        _quickReplies = const [];
        _skillMenu = const [];
      });
    }
    // Slash commands answer in the chat itself - there is no settings
    // screen to go to any more.
    if (await _handleCommand(text)) {
      _input.clear();
      return;
    }
    // "Undo that" is answered from the exact change log, before a model is
    // consulted. Asking a model which value it typed earlier is how undo
    // becomes a guess.
    if (await _handleUndo(text)) {
      _input.clear();
      return;
    }
    // "fix the plan" - answered here, before any model is consulted, because
    // the findings are this app's own and the repair for them is deterministic
    // and offline. Whether a key is set must not decide whether the user can
    // act on the findings the app just reported.
    if (await _handlePlanRepair(text)) {
      _input.clear();
      return;
    }
    final settings = _settings;
    final mem = _memory;
    final attachments = List<ChatImage>.from(_pending);
    _input.clear();
    setState(() {
      _busy = true;
      _pending = [];
      _status = 'Thinking...';
    });
    final token = _generation.begin();

    // Parse the request into a structured plan on every turn, so
    // "build the .pkt" always has something real to compile. This is the same
    // parse the offline planner uses, so the result does not depend on
    // whether a model answered.
    //
    // An OFF-TOPIC message is never parsed: a coding request must not update
    // the standing plan (the parser would fall back to a default lab the user
    // never asked for).
    // The Understood card is off until THIS turn's parse succeeds: a turn
    // that is declined or fails must not wear an older turn's plan.
    // Whether a plan was already standing BEFORE this turn was parsed.
    // An edit turn parses to the change, not to the lab, so what this turn
    // parses must not be mistaken for the network being edited.
    final hadStandingPlan = _lastIntent != null;
    _understoodOk = false;
    _slotFixNote = null;
    // A design applied last turn is history now; this turn either applies
    // another one or leaves the plan as it stands.
    _appliedDesign = null;
    // SMALL TALK IS NOT A BRIEF. "hello" names no devices, so parsing it
    // invented a default 1-router lab and the reply announced a network the
    // user never described. With no plan standing there is nothing to edit
    // and nothing to plan from, so the turn is conversation only.
    final smallTalk = !hadStandingPlan && ScopeGate.isSmallTalk(text);
    // TENTATIVE LANGUAGE: "could we do it with 40 PCs?" is the user wondering
    // about the design, not ordering a rebuild. The gate reads the turn BEFORE
    // the parse, so an exploring sentence never reaches NetworkIntent.followUp
    // (or the phrasing teacher or the design catalog) and the standing lab
    // stays exactly as it is - a wrong mutation is the most expensive
    // misunderstanding this app can make.
    final exploring = !smallTalk &&
        !ScopeGate.isOffTopic(text) &&
        TentativeLanguageService.analyze(
          CasualEnglish.normalize(text).trim(),
        ).tentative;
    if (!ScopeGate.isOffTopic(text) && !smallTalk && !exploring) {
      try {
        final normalized = CasualEnglish.normalize(text);
        final brief = normalized.trim().isEmpty ? text : normalized;
        _previousIntent = _lastIntent;
        _previousBrief = _lastBrief;
        // One place decides what the standing plan becomes (addition, change,
        // new lab, or unchanged) - see NetworkIntent.followUp.
        final outcome = NetworkIntent.followUp(
          previous: _previousIntent,
          previousBrief: _lastBrief,
          brief: brief,
          parsed: NetworkIntent.parseSimple('chat', brief),
          project: 'chat',
        );
        // LEARNING, without a model: when this turn turned an
        // underspecified earlier phrasing into a resolved brief (the user
        // clarified, or a change landed), the pair is remembered so the same
        // words get the same plan next time - see [PhrasingMemoryService].
        await PhrasingMemoryService.teachIfResolved(
          mem?.teachPhrasing ?? _noopTeach,
          keyText: _lastBrief,
          keyNodes: _previousIntent?.nodes.length ?? 0,
          resolvedBrief: outcome.brief,
          resolvedNodes: outcome.plan.nodes.length,
        );
        _lastIntent = outcome.plan;
        _lastBrief = outcome.brief;
        // "Rebuild it with the DMZ design" is a request the catalog can
        // answer exactly, so it is answered here rather than handed to the
        // model to improvise. The review is re-run on the result so the
        // number shown after a rebuild reflects the design that was applied.
        final designed = DesignApplier.applyNamed(_lastIntent!, brief);
        if (designed != null) {
          _lastIntent = designed.plan;
          _appliedDesign = (
            design: designed.design,
            added: designed.added,
            skipped: designed.skipped,
          );
          _understoodOk = true;
          _reportAppliedDesign(_appliedDesign!);
        }
        _understoodOk = true;
      } catch (_) {
        // Keep the previous plan rather than losing it to a parse failure.
      }
      // COUNT THE TURNS THE PARSER WROTE A PLAN FOR. The misparse rate on
      // the Memory screen is corrections per parsed turn, and without this
      // denominator "improving" would be a feeling rather than a number.
      if (_understoodOk) {
        try {
          await mem?.noteParsedTurn();
        } catch (_) {
          // A missed counter is not worth failing a send over.
        }
      }
    }
    // The history the provider is given must END BEFORE this turn: both
    // providers append the pending text themselves, so sending the appended
    // list as well made every message appear twice in model context.
    final historyBeforeCurrent = List<ChatMessage>.from(_messages);

    // "EDIT IT" IS A QUESTION ABOUT A FILE THAT EXISTS.
    //
    // Read before the model is consulted, because the failure this prevents is
    // a second .pkt appearing next to the first one with no word of warning.
    // An ambiguous request gets the choice; a clear one just goes.
    //
    // A message that NAMES one of the files this conversation produced
    // ("edit netbuilder-...1236.pkt") is a clear request about that file,
    // however it is phrased - resolved before the reader so a named file
    // never lands in the ambiguous branch.
    // A request to SEE the drawing is not a request to CHANGE it. Read before
    // [LayoutRequest.read], which would read "drawing" as a vague redraw and
    // cycle the style - the user asking to look at the picture and getting a
    // different picture instead.
    if (_isPreviewRequest) {
      final ask = ChatMessage(
        role: 'user',
        text: text,
        images: attachments,
        createdAt: DateTime.now().toIso8601String(),
      );
      _state.observe(ask).withIntent(_lastIntent);
      setState(() {
        _messages = [..._messages, ask];
        _activity = const [];
        _busy = false;
        _status = '';
      });
      _jumpToEnd();
      if (mem != null && mem.ready) {
        try {
          await mem.logChat(ask, conversation: _conversation);
        } catch (_) {}
      }
      final opened = await _previewLayout('');
      if (!opened) {
        setState(() {
          _messages = [
            ..._messages,
            ChatMessage(
              role: 'model',
              text:
                  'There is no plan to draw yet. Describe the network first '
                  'and I will show you the layout before it is built.',
              createdAt: DateTime.now().toIso8601String(),
              source: AiStatus.plannerSource,
            ),
          ];
        });
        _jumpToEnd();
      }
      return;
    }

    // "IT LOOKS BAD" IS A REQUEST ABOUT THE DRAWING, NOT ABOUT THE NETWORK.
    //
    // Read before the file-edit reader and before any provider: "can you edit
    // the layout of the devices to make them better looking?" matched the
    // ordinary edit intent, so the app recompiled the same plan and the same
    // deterministic coordinates came back - the user read that as being
    // ignored. A redraw now picks a drawing that is different from the one on
    // the table (or the one the user named) and says which it used.
    final drawingRequest = LayoutRequest.read(
      text,
      currentStyle: _layoutStyleOf(_artifactPath),
    );
    if (drawingRequest != null) {
      final hasSomethingToRedraw =
          _state.knownArtifacts.isNotEmpty || _artifactPath.trim().isNotEmpty;
      if (hasSomethingToRedraw) {
        final ask = ChatMessage(
          role: 'user',
          text: text,
          images: attachments,
          createdAt: DateTime.now().toIso8601String(),
        );
        _state.observe(ask).withIntent(_lastIntent);
        setState(() {
          _messages = [..._messages, ask];
          _activity = const [];
        });
        _jumpToEnd();
        if (mem != null && mem.ready) {
          try {
            await mem.logChat(ask, conversation: _conversation);
          } catch (_) {}
        }
        await _redrawPkt(drawingRequest);
        return;
      }
      // Nothing built yet. Remember the drawing AND say so, then keep going:
      // this branch used to fall through in silence, so "move the servers to
      // the side" before a first build re-analysed the plan and answered as
      // though no layout had been asked for.
      _rememberLayout(drawingRequest, const <LayoutZone>[]);
      setState(() {
        _messages = [
          ..._messages,
          ChatMessage(
            role: 'model',
            text:
                'I have noted the drawing you asked for — '
                '**${drawingRequest.style}**, ${drawingRequest.describe()}. '
                'There is no .pkt yet, so there is nothing to redraw; the next '
                'file I build will use it.',
            createdAt: DateTime.now().toIso8601String(),
            source: AiStatus.plannerSource,
          ),
        ];
      });
      _jumpToEnd();
    }

    final files = _state.knownArtifacts;
    final namedArtifact = _resolveNamedArtifact(text);
    final fileIntent = namedArtifact.isNotEmpty
        ? FileEditIntent.editExisting
        : FileEditIntentReader.read(
            text,
            hasArtifact: files.isNotEmpty,
            candidates: files.length,
          );
    // Ask which file only when the target genuinely is ambiguous: several
    // files this conversation produced and none of them named. One file that
    // the user pointed at IS that file, so "edit the file and make one server
    // an AAA server" goes straight to the edit instead of asking a question
    // the user just answered.
    final needsFileChoice =
        namedArtifact.isEmpty &&
        files.length > 1 &&
        (fileIntent == FileEditIntent.editExisting ||
            fileIntent == FileEditIntent.ambiguous);
    if (fileIntent == FileEditIntent.ambiguous || needsFileChoice) {
      final ask = ChatMessage(
        role: 'user',
        text: text,
        images: attachments,
        createdAt: DateTime.now().toIso8601String(),
      );
      final choice = files.length > 1
          ? _fileMultiChoiceTurn(files)
          : _fileChoiceTurn(text);
      setState(() {
        _messages = [..._messages, ask, choice];
        _status = '';
        _quickReplies = files.length > 1
            ? [
                for (final f in files.take(3)) 'Edit ${f.name}',
                'Create a new file instead',
              ]
            : FileEditIntentReader.choiceReplies(_artifactName);
      });
      _jumpToEnd();
      if (mem != null && mem.ready) {
        try {
          await mem.logChat(ask, conversation: _conversation);
          await mem.logChat(choice, conversation: _conversation);
        } catch (_) {}
      }
      if (mounted) setState(() => _busy = false);
      return;
    }
    final editInPlace = fileIntent == FileEditIntent.editExisting;
    final userTurn = ChatMessage(
      role: 'user',
      text: text,
      images: attachments,
      createdAt: DateTime.now().toIso8601String(),
    );
    // LAYER 2: fold the new turn into the structured state before anything is
    // sent, so "what about its gateway?" is answerable from data rather than
    // from the model's recollection.
    _state.observe(userTurn).withIntent(_lastIntent);
    // The standing plan travels with the conversation (secrets redacted), so
    // "add a switch to it" three messages later edits the same lab after a
    // restart instead of planning from nothing.
    final standing = _lastIntent;
    if (standing != null) {
      _state.withIntentJson(jsonEncode(standing.toJson(includeSecrets: false)));
    }
    setState(() {
      _messages = [..._messages, userTurn];
      _activity = const [];
      _activityOpen = true;
    });
    _jumpToEnd();
    if (mem != null && mem.ready) {
      try {
        await mem.logChat(userTurn, conversation: _conversation);
        await mem.ensureConversation(
          _conversation,
          project: _project.text.trim(),
        );
        await mem.setSessionState(_conversation, _state.encode());
      } catch (_) {}
    }

    // A clear "edit it" with no choice to make: the plan is updated, and the
    // answer is the file being rewritten rather than a second one appearing.
    if (editInPlace) {
      final targetPath = namedArtifact.isNotEmpty
          ? namedArtifact
          : _artifactPath;
      if (!hadStandingPlan) {
        // There is a file but no plan behind it in this conversation, so what
        // this turn parsed is the edit and nothing else: "...and make one
        // server an AAA server" is one server. Compiling that over the file
        // would replace a whole lab with the fragment the user mentioned, so
        // the fragment is dropped and the answer names the file instead.
        _lastIntent = _previousIntent;
        _lastBrief = _previousBrief;
        _understoodOk = false;
        final turn = ChatMessage(
          role: 'model',
          text: FileEditIntentReader.noPlanText(
            targetPath.split(RegExp(r'[/\\]')).last,
          ),
          createdAt: DateTime.now().toIso8601String(),
        );
        setState(() {
          _messages = [..._messages, turn];
          _busy = false;
          _status = '';
        });
        _jumpToEnd();
        if (mem != null && mem.ready) {
          try {
            await mem.logChat(turn, conversation: _conversation);
            await mem.setSessionState(_conversation, _state.encode());
          } catch (_) {}
        }
        return;
      }
      await _editPktInPlace(targetPath);
      return;
    }

    if (settings == null) {
      _appendError('<no settings provider>');
      if (mounted) setState(() => _busy = false);
      return;
    }
    // PRIVATE MODE IS A KILL SWITCH, not a preference the chat happens to
    // honour somewhere else: the user is told it never calls the model, so
    // this turn must not reach a provider, a tool loop or a web search.
    if (settings.privateMode) {
      try {
        await _appendOfflinePlan(text, 'private mode is on', privateMode: true);
        _failedText = null;
      } catch (offlineError) {
        if (mounted) {
          setState(() {
            _failedText = text;
            _input.text = text;
            _status =
                'Could not answer offline ($offlineError). Your message '
                'is still in the box - press Enter to retry.';
          });
        }
      } finally {
        if (mounted) setState(() => _busy = false);
      }
      return;
    }
    try {
      // Refresh the key in case it was just added in Settings, then build the
      // provider facade (which carries the probed runtime window). A cleared
      // key becomes empty rather than keeping the previous value.
      _geminiKey = await settings.getApiKey() ?? '';
      _openAiKey = await settings.getOpenAiKey() ?? '';
      final parts = await _buildContext(mem, text);
      _memories = parts.memories;
      final service = _chat ?? _buildChat(settings);
      // STREAM the answer in, the way a chat model does: the bubble grows
      // as tokens arrive instead of the user staring at a spinner.
      final live = StringBuffer();
      ChatMessage? partial;

      /// One place where a streamed piece becomes a visible turn, so the
      /// tool path and the plain path cannot diverge.
      void show(String piece) {
        live.write(piece);
        if (!mounted) return;
        // Structured replies arrive as JSON; show the growing reply text,
        // not the scaffolding. Non-JSON pieces (status lines, offline
        // answers) pass through untouched.
        final preview = ChatService.streamPreview(live.toString());
        setState(() {
          final liveTurn = ChatMessage(
            role: 'model',
            text: preview ?? live.toString(),
            createdAt: DateTime.now().toIso8601String(),
          );
          if (partial == null) {
            _messages = [..._messages, liveTurn];
            partial = liveTurn;
          } else {
            _messages = [..._messages]..last = liveTurn;
          }
        });
        _noteNewMessage();
      }

      // THREE KINDS OF TURN, one presentation:
      //
      //  * the engine offered tools -> drive the tool loop and turn its
      //    events into REAL activity entries plus the answer (no invented
      //    reasoning is ever shown);
      //  * plain model -> stream the tokens;
      //  * no model -> the existing offline path in the catch below.
      if (service.usesTools) {
        // The tool path gets the SAME conversation the plain path does: the
        // live network, the structured state, the recalled memories, the saved
        // summary and the screenshots on this turn. It used to pass only the
        // system prompt and the text, so a turn answered with tools was a
        // different (and much dumber) conversation.
        await for (final event in service.executeToolConversation(
          history: historyBeforeCurrent.where((m) => !m.isError).toList(),
          text: text,
          systemContext: parts.system,
          attachments: attachments,
          networkContext: parts.network,
          sessionState: parts.session,
          memories: parts.memories,
          storedSummary: parts.summary,
          abortTrigger: _generation.abortTrigger,
          // Read synchronously: a cancel that happened before this request was
          // built is invisible to a future, and the request would go out anyway.
          abortProbe: () => !_generation.isCurrent(token),
        )) {
          if (!_generation.isCurrent(token)) break;
          if (!mounted) return;
          switch (event.kind) {
            case 'status':
              setState(() {
                _activity = [
                  ..._activity,
                  ActivityEntry(event.text, status: ActivityStatus.running),
                ];
              });
            case 'result':
              final failed =
                  event.data is Map && (event.data as Map).containsKey('error');
              setState(() {
                _activity = [
                  ..._activity.take(_activity.length - 1),
                  if (failed)
                    ActivityEntry(
                      event.call?.name ?? 'tool',
                      detail: 'failed',
                      status: ActivityStatus.failed,
                    )
                  else if (_activity.isNotEmpty)
                    _activity.last.copyWith(status: ActivityStatus.ok),
                ];
              });
            case 'limit':
              setState(() {
                _activity = [
                  ..._activity,
                  ActivityEntry(event.text, status: ActivityStatus.warning),
                ];
              });
            case 'final':
              if (event.text.trim().isNotEmpty) show(event.text);
          }
        }
      } else {
        await for (final piece in service.streamWithTools(
          history: historyBeforeCurrent.where((m) => !m.isError).toList(),
          text: text,
          systemContext: parts.system,
          attachments: attachments,
          networkContext: parts.network,
          sessionState: parts.session,
          memories: parts.memories,
          storedSummary: parts.summary,
          // Stop has to reach the transport on this path too, otherwise a
          // cancelled turn keeps its request (and its tool calls) running
          // until the provider's own timeout.
          abortTrigger: _generation.abortTrigger,
          abortProbe: () => !_generation.isCurrent(token),
        )) {
          // The user may have pressed stop while this was arriving.
          if (!_generation.isCurrent(token)) break;
          show(piece);
        }
      }
      // The model answered: a previously failing provider has recovered,
      // so the header sign goes back to its normal state.
      if (_lastModelError.isNotEmpty) {
        _lastModelError = '';
        if (mounted) setState(() {});
      }
      // Anything the engine's own tools reported is a finding the app can
      // stand behind; the structured state keeps them for follow-ups.
      for (final entry in _activity) {
        if (entry.status == ActivityStatus.failed) {
          _state.addFinding('${entry.label} failed', confirmed: false);
        }
      }
      final reply = ChatService.parseReply(live.toString());
      final turn = ChatMessage(
        role: 'model',
        text: reply.text.isEmpty && reply.actions.isEmpty
            ? '(the model returned nothing usable)'
            : reply.text,
        actions: reply.actions,
        createdAt: DateTime.now().toIso8601String(),
        // This turn really did come from the API model, so it is stamped
        // with where it came from. (A failure would have taken the offline
        // path below, which stamps its own source.)
        source: _aiStatus.source,
      );
      if (!mounted) return;
      setState(() {
        // The live bubble becomes the final turn (with its action cards)
        // rather than being left behind as a duplicate.
        if (partial != null && _messages.isNotEmpty) {
          _messages = [..._messages]..last = turn;
        } else {
          _messages = [..._messages, turn];
        }
        _status = reply.questions.isEmpty
            ? ''
            : 'The assistant asks: ${reply.questions.join('  |  ')}';
      });
      _jumpToEnd();
      // The question is answered: fold the answer into the structured state,
      // persist it, and close the activity panel (the work is done - the panel
      // stays open only while it is still happening or when it found
      // something worth reading).
      _state.observe(turn);
      final plan = service.lastPlan;
      if (plan != null) {
        _requestReport = plan.report;
      }
      if (mounted) {
        setState(() {
          _activityOpen = _activity.any(
            (a) =>
                a.status == ActivityStatus.failed ||
                a.status == ActivityStatus.warning,
          );
        });
      }
      if (mem != null && mem.ready) {
        try {
          await mem.logChat(turn, conversation: _conversation);
          // LEARNED ANSWERS: a completed keyed-model reply to a
          // question-shaped ask is knowledge worth replaying offline. The
          // decision (learn / agree / reject, and the smart pick across
          // answers the model gave before) is [LearnedAnswers]'s; this
          // only feeds it, only on a generation that finished on its own
          // terms, and never lets a learning hiccup cost the turn.
          if (_generation.isCurrent(token) &&
              reply.text.isNotEmpty &&
              LearnedAnswers.isLearnableQuestion(text)) {
            try {
              await mem.learnAnswer(
                question: text,
                answer: reply.text,
                source: _aiStatus.source,
              );
            } catch (_) {}
          }
          // PREFERENCE AUTO-TEACH: "always use OSPF" is a rule for every
          // plan after it, not just this turn. Stated plainly (always /
          // from now on / prefer), it is remembered without a button press
          // - gated by the Learn-automatically setting.
          await _autoTeachPreference(text);
          // ENVIRONMENT AUTO-LEARN: "this is for the office, 40 users"
          // feeds the remembered profile the advisor falls back to.
          await _updateEnvironmentProfile(text);
          await mem.setSessionState(_conversation, _state.encode());
          // Persist the compacted summary of the turns that did not fit, so
          // the next request re-uses it instead of summarizing a summary.
          if (plan != null &&
              plan.turnsSummarized > 0 &&
              plan.memoryBlock.isNotEmpty &&
              plan.memoryBlock != _storedSummary) {
            _storedSummary = plan.memoryBlock;
            await mem.setConversationSummary(_conversation, _storedSummary);
          }
          await _autoTitleFirstTurn(mem);
        } catch (_) {}
      }
      await _refreshConversations();
    } catch (e) {
      // A turn the user stopped is not a failure and is not answered by the
      // offline assistant: the text that already arrived stays, the turn just
      // stops. Falling through here answered a cancellation with a "the model
      // is down" style reply to a request the user had just cancelled.
      if (e is AbortedException || !_generation.isCurrent(token)) {
        _failedText = null;
      } else {
        // No key, no quota, model busy, no network: answer from the offline
        // assistant so the user still gets a normal, advisory reply. If even
        // that fails, the typed message is put back so Enter retries it.
        try {
          _lastModelError = e
              .toString()
              .replaceFirst('Exception: ', '')
              .split('\n')
              .first
              .trim();
          if (mounted) setState(() {});
          await _appendOfflinePlan(text, e);
          _failedText = null;
        } catch (offlineError) {
          if (mounted) {
            setState(() {
              _failedText = text;
              _input.text = text;
              _status =
                  'Could not answer ($offlineError). Your message is '
                  'still in the box - press Enter to retry.';
            });
          }
        }
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Answer a message without the model, using the deterministic planner and
  /// the offline assistant. This is what makes the keyless chat a normal
  /// conversation instead of an error: it always says something useful, and
  /// when it cannot plan, it asks for what it needs.
  Future<void> _appendOfflinePlan(
    String text,
    Object error, {
    bool privateMode = false,
  }) async {
    final normalized = CasualEnglish.normalize(text);
    NetworkIntent? plan;
    List<String> suggestions = const [];
    bool briefChanged = false;
    // THE TENTATIVE GATE RUNS FIRST - before the pending questions, because a
    // what-if must not be read as an answer either: "what if we used OSPF?"
    // while the routing question is open would otherwise fill it in. An
    // exploring turn is answered as a conversation and changes nothing: no
    // plan, no brief, no cards, no remembered answer.
    if (!ScopeGate.isOffTopic(text) &&
        TentativeLanguageService.analyze(
          normalized.isEmpty ? text : normalized,
        ).tentative) {
      await _answerTentative(text, normalized, privateMode: privateMode);
      return;
    }
    // A PENDING QUESTION TURNS THE NEXT MESSAGE INTO ITS ANSWER: when this
    // message resolves one, apply it, remember it for this environment, and
    // do not treat it as a new request. Unresolved text falls through to the
    // normal routing (the user changed the subject; the questions stay).
    if (_state.pendingQuestionIds.isNotEmpty && !ScopeGate.isOffTopic(text)) {
      final answered = await _resolvePendingClarification(
        normalized.isEmpty ? text : normalized,
      );
      if (answered != null) {
        await _applyClarificationAnswer(answered);
        return;
      }
    }
    // An off-topic message gets the scope decline, never a parsed plan: the
    // standing plan and its action cards stay untouched.
    if (!ScopeGate.isOffTopic(text)) {
      try {
        final rules = await _learnedRules();
        final prefs = await _learnedPrefs();
        final parsed = NetworkIntent.parseSimple(
          'offline-chat',
          normalized.isEmpty ? text : normalized,
        );
        final withMemory = PlannerMemoryService.apply(
          parsed,
          rules: rules,
          preferences: prefs,
        );
        // The offline planner is the one that always exists, so its plan is what
        // the builder offers to compile. Same decision as the online path - one
        // entry point, so the two cannot disagree about what is being built.
        final brief = normalized.isEmpty ? text : normalized;
        final outcome = NetworkIntent.followUp(
          previous: _previousIntent,
          previousBrief: _previousBrief,
          brief: brief,
          parsed: withMemory,
          project: 'offline-chat',
        );
        // A merged plan came from a re-read of the original request, so the
        // learned rules are applied to it too rather than lost in the merge.
        final reconciled = identical(outcome.plan, withMemory)
            ? outcome.plan
            : PlannerMemoryService.apply(
                outcome.plan,
                rules: rules,
                preferences: prefs,
              );
        _lastIntent = reconciled;
        _lastBrief = outcome.brief;
        // The reconciled plan is what the reply and the build card below
        // describe, so it is also what this conversation must record: the
        // caller already recorded its first parse of this turn (which ran
        // without the learned rules), and leaving that record in place
        // would bring a different network back on reopen than the one on
        // the screen right now.
        _state.withIntentJson(
          jsonEncode(reconciled.toJson(includeSecrets: false)),
        );
        // THE BRIEF: fold what this turn settled into the running brief -
        // the user's words first, then what the plan shows they decided,
        // then the environment profile for what nobody said. The brief, not
        // the parse, decides when a build is offered.
        final briefTurn = DesignBriefService.briefForTurn(
          previous: _brief,
          normalizedText: brief,
          parsedPlan: reconciled,
          profile: await _loadEnvironmentProfile(),
          // Taught rules are the user's own words, just older: they fill
          // the brief at user rank so the app never asks what it has
          // already been told ("always use ospf" answers the routing
          // question before it is asked).
          standingRules: rules,
        );
        _brief = briefTurn.brief;
        _state.briefJson = jsonEncode(_brief.toJson());
        briefChanged = briefTurn.changed;
        // The answer describes the plan that actually stands, not the one this
        // message parsed to on its own. "Use OSPF" parses to an empty brief, and
        // the parser's fallback lab is not what the user has been building.
        plan = reconciled;
        suggestions = PlannerSuggestionsService.forIntent(
          reconciled,
          target: _target,
        );
      } catch (_) {
        plan = null;
      }
    } // !isOffTopic
    final reason = error
        .toString()
        .replaceFirst('Exception: ', '')
        .split('\n')
        .first
        .trim();
    // LEARNED ANSWERS: the same question answered by the keyed model
    // before is replayed here, offline. Loaded before the reply so the
    // assistant can lead with the exact answer the model gave.
    final mem = _memory;
    LearnedAnswer? learned;
    if (mem != null && mem.ready) {
      try {
        learned = await mem.bestLearnedAnswer(text);
      } catch (_) {}
    }
    // The remembered environment: the advisor still believes the message
    // first, but facts it leaves unsaid come from here instead of falling
    // back to generic.
    final envProfile = await _loadEnvironmentProfile();
    // ASK BEFORE PLAN: with critical gaps still open, the chat asks instead
    // of committing a plan - unless the user insisted ("just build it"),
    // in which case the safe defaults are visible on the brief card.
    List<ClarificationQuestion> clarifying = const [];
    if (plan != null && plan.nodes.isNotEmpty) {
      if (_brief.ready || _isForcedBuild(normalized.isEmpty ? text : normalized)) {
        _state.pendingQuestionIds = const [];
      } else {
        clarifying = await _clarificationsFor(plan, envProfile);
        _state.pendingQuestionIds = [for (final q in clarifying) q.id];
      }
    }
    final reply = OfflineAssistantService.reply(
      rawText: text,
      normalized: normalized,
      target: _target,
      plan: plan,
      previousPlan: _previousIntent,
      suggestions: suggestions,
      modelError: reason,
      // The offline assistant is stateless without this: the turns are
      // how it remembers what the user asked first.
      history: _messages.where((m) => !m.isError).toList(),
      privateMode: privateMode,
      // Files this conversation produced - "show saved networks" reports
      // what is real, including each build's verification note.
      knownArtifacts: [
        for (final f in _state.knownArtifacts) (name: f.name, note: f.note),
      ],
      // An active troubleshooting ladder owns the turn: hand its state in
      // so the flow's next step (or its exit) is what gets answered.
      activeFlow: _state.flowState.isNotEmpty ? _state.flowState : null,
      // The learned answer for this exact question, when one exists.
      learnedAnswer: learned,
      // The remembered venue/scale/budget/skill, when one has been learned.
      environmentProfile: envProfile,
      // Critical gaps to ask about instead of committing a plan. Empty once
      // the brief is ready or the user insisted on a build.
      clarifyingQuestions: clarifying,
    );
    // A troubleshooting reply carries the flow's next state: store it (an
    // empty map means the flow ended and must not ghost into the next
    // turn), so the ladder survives a conversation reopen via
    // setSessionState below.
    if (reply.flowState != null) {
      _state.flowState = reply.flowState!;
    }
    // An answer that repaired the plan changed it: the repaired version is
    // what stands from here, so the card below is written for it and the next
    // turn plans on top of it instead of the broken one.
    final repaired = reply.repairedPlan;
    if (repaired != null && repaired.nodes.isNotEmpty) {
      _lastIntent = repaired;
      plan = repaired;
      _state.withIntentJson(jsonEncode(repaired.toJson(includeSecrets: false)));
      // Park what the repair would teach. Nothing reads it until a build of
      // this exact plan comes back verified - see MemoryService.
      await _parkRepairLearning(repaired, reply.repairedFixes);
    }
    final turn = ChatMessage(
      role: 'model',
      text: '',
      createdAt: DateTime.now().toIso8601String(),
      // WHERE THIS ANSWER CAME FROM, on the turn itself: the offline
      // assistant. The words no longer open the answer (the header sign says
      // the state once, the source line sits under the turn), so the answer
      // can start with its content instead of an apology.
      source: _aiStatus.source,
      // Offered whether or not a key is set: the plan is already parsed, so
      // the .pkt can be built either way. The card is stamped with the plan
      // version the answer above describes, so the card, the summary and the
      // compiled file all name the same network.
      //
      // Not offered for an EMPTY plan. A greeting parses to a plan with no
      // devices, and a build card over it advertised "0 device(s), 0 link(s)"
      // and refused itself with the finding "No nodes defined" - a build
      // button for a network that does not exist yet.
      //
      // An advice answer carries its structured advice card alongside: the
      // recommendation, the options and the "Plan this" button render from
      // the payload, not from parsing the markdown back.
      //
      // THE BUILD CARD IS GATED ON THE BRIEF, not on the parse: with
      // clarifications pending there is nothing to compile yet - the answer
      // asks instead. The brief card rides when the brief moved, except on
      // the asking turn itself - see the action list below.
      actions: [
        if (plan != null && plan.nodes.isNotEmpty && clarifying.isEmpty)
          _buildCardFor(plan),
        // The brief card rides when the brief moved - EXCEPT on the turn
        // that is asking: there the questions ARE the open list, and a card
        // repeating "still open" beside them says the same thing twice.
        if (briefChanged && clarifying.isEmpty) _briefCardFor(_brief),
        if (reply.advice != null) _adviceCardFor(reply.advice!),
      ],
    );
    if (!mounted) return;
    setState(() {
      _messages = [..._messages, turn];
      _status = '';
      _quickReplies = reply.quickReplies;
      // A plan that contradicts itself asks above the box; a plan that does
      // not clears the question.
      _planPrompt = _nextPlanPrompt(plan);
    });
    _jumpToEnd();

    // The offline answer is computed, not streamed - but it should still
    // arrive like an answer rather than appear whole. Progressively revealed,
    // the whole thing lands in well under a second.
    final answer = ChatMessage(
      role: 'model',
      text: reply.text,
      createdAt: turn.createdAt,
      actions: turn.actions,
    );
    // THE RECORD MUST NOT WAIT ON THE ANIMATION. The structured state is
    // written the moment the answer exists: the reveal is a courtesy, and a
    // conversation reopened - or an app killed - halfway through it must come
    // back to the plan on the screen, not to the turn's first parse. The
    // store writes that follow (the log, the teaching) still land when the
    // answer is whole.
    _state.observe(answer);
    final earlyStore = _memory;
    if (earlyStore != null && earlyStore.ready) {
      try {
        await earlyStore.setSessionState(_conversation, _state.encode());
      } catch (_) {}
    }
    _revealAnswer(
      turn,
      reply.text,
      // OFFLINE TURNS ARE REMEMBERED TOO, once the answer is whole. They used
      // to be appended to the screen and nowhere else, so reopening a keyless
      // conversation showed the user's questions with none of the answers -
      // the app looked like it had lost half the chat.
      onDone: () async {
        final mem = _memory;
        if (mem == null || !mem.ready) return;
        try {
          await mem.logChat(answer, conversation: _conversation);
          // Same preference auto-teach as the model path: "always use a
          // 4331" typed while offline is a rule too.
          await _autoTeachPreference(text);
          // And the environment profile learns the same way offline.
          await _updateEnvironmentProfile(text);
          await mem.setSessionState(_conversation, _state.encode());
          await _autoTitleFirstTurn(mem);
        } catch (_) {}
        await _refreshConversations();
      },
    );
  }

  /// What every exploring answer says when its own branch did not already say
  /// it: the guarantee this gate exists to keep, in the user's words.
  static const String _exploringTail =
      '\n\nNothing in your lab changed - that was a what-if, not a change. '
      'Ask for it as a change ("make it 40 PCs", "use OSPF instead") and I '
      'will do it.';

  /// Answer an EXPLORING turn: "could we do it with 40 PCs?", "what if we
  /// used OSPF instead?", "would a DMZ be better here?".
  ///
  /// The standing plan is passed as CONTEXT - the question is about the lab
  /// that exists - and this method writes none of it back: no
  /// [NetworkIntent.followUp], no [DesignBrief] update, no build card, no
  /// remembered clarification. The reply still lands in the transcript like
  /// any other answer, because a conversation the app does not write down is
  /// a conversation it cannot continue after a reopen.
  Future<void> _answerTentative(
    String text,
    String normalized, {
    bool privateMode = false,
  }) async {
    final mem = _memory;
    LearnedAnswer? learned;
    if (mem != null && mem.ready) {
      try {
        learned = await mem.bestLearnedAnswer(text);
      } catch (_) {}
    }
    final reply = OfflineAssistantService.reply(
      rawText: text,
      normalized: normalized,
      target: _target,
      plan: _lastIntent,
      previousPlan: _previousIntent,
      history: _messages.where((m) => !m.isError).toList(),
      privateMode: privateMode,
      knownArtifacts: [
        for (final f in _state.knownArtifacts) (name: f.name, note: f.note),
      ],
      activeFlow: _state.flowState.isNotEmpty ? _state.flowState : null,
      learnedAnswer: learned,
      environmentProfile: await _loadEnvironmentProfile(),
      // The questions wait: a what-if is not an answer to one, and asking
      // again in the middle of somebody wondering out loud is how a
      // conversation turns into a form.
      clarifyingQuestions: const [],
    );
    // The advice branch already closes with its own "nothing changed" line,
    // and the scope decline speaks for itself; every other branch gets the
    // guarantee, so no exploring answer ever leaves it implied.
    final body = reply.intent == 'advice' || reply.intent == 'offtopic'
        ? reply.text
        : '${reply.text}$_exploringTail';
    if (!mounted) return;
    final turn = ChatMessage(
      role: 'model',
      text: '',
      createdAt: DateTime.now().toIso8601String(),
      source: _aiStatus.source,
      actions: const [],
    );
    setState(() {
      _messages = [..._messages, turn];
      _status = '';
      _quickReplies = reply.quickReplies;
    });
    _jumpToEnd();
    final answer = ChatMessage(
      role: 'model',
      text: body,
      createdAt: turn.createdAt,
      actions: const [],
    );
    _state.observe(answer);
    final store = _memory;
    if (store != null && store.ready) {
      try {
        await store.setSessionState(_conversation, _state.encode());
      } catch (_) {}
    }
    _revealAnswer(turn, body, onDone: () async {
      final store = _memory;
      if (store == null || !store.ready) return;
      try {
        await store.logChat(answer, conversation: _conversation);
        await store.setSessionState(_conversation, _state.encode());
        await _autoTitleFirstTurn(store);
      } catch (_) {}
      await _refreshConversations();
    });
  }

  /// Reveal a computed answer at a reading pace.
  ///
  /// One `Timer` at a time, held in [_reveal]. A reveal that is still running
  /// when the next turn arrives (or when the screen goes away) is *finished*
  /// rather than dropped: the answer is already written, and dropping it would
  /// lose the turn from the store.
  void _revealAnswer(
    ChatMessage template,
    String full, {
    VoidCallback? onDone,
  }) {
    _revealFinish?.call();
    if (full.isEmpty) {
      onDone?.call();
      return;
    }
    // The turn was appended by the caller, so it is the last one. Holding the
    // index keeps a later turn - another message in the same second - safe.
    final index = _messages.length - 1;
    var end = 0;
    var done = false;

    void write(String piece) {
      if (!mounted || index < 0 || index >= _messages.length) return;
      setState(() {
        final next = [..._messages];
        next[index] = ChatMessage(
          role: template.role,
          text: piece,
          createdAt: template.createdAt,
          actions: template.actions,
          // The source line survives the reveal: it is part of the turn,
          // not part of the text being typed out.
          source: template.source,
        );
        _messages = next;
      });
      _noteNewMessage();
    }

    void settle({required bool onScreen}) {
      if (done) return;
      done = true;
      _reveal?.cancel();
      _reveal = null;
      _revealFinish = null;
      _revealPersist = null;
      if (onScreen) write(full);
      onDone?.call();
    }

    void complete() => settle(onScreen: true);

    void step() {
      if (done) return;
      end = end + kRevealChunk >= full.length ? full.length : end + kRevealChunk;
      write(full.substring(0, end));
      if (end < full.length) {
        _reveal = Timer(kRevealTick, step);
      } else {
        complete();
      }
    }

    _revealFinish = complete;
    _revealPersist = () => settle(onScreen: false);
    step();
  }

  void _appendError(String message) {
    final turn = ChatMessage(
      role: 'system',
      text: 'Could not reach the model: $message',
      createdAt: DateTime.now().toIso8601String(),
    );
    if (!mounted) return;
    setState(() => _messages = [..._messages, turn]);
    _jumpToEnd();
  }

  // --- attachments -------------------------------------------------------

  Future<void> _pickImageFiles() async {
    try {
      final picked = await FilePicker.platform.pickFiles(
        type: FileType.image,
        allowMultiple: true,
      );
      if (picked == null) return;
      for (final file in picked.files) {
        List<int>? bytes = file.bytes;
        if (bytes == null && file.path != null) {
          bytes = await File(file.path!).readAsBytes();
        }
        if (bytes == null) continue;
        final result = await _chat!.persistImage(
          bytes: bytes,
          name: file.name,
          mimeType: _mimeFor(file.name),
        );
        if (!mounted) return;
        if (!result.ok) {
          setState(() => _status = result.error);
          continue;
        }
        setState(() => _pending = [..._pending, result.image!]);
      }
    } catch (e) {
      // A person reads this, not a log: say what failed and what to do about
      // it, in the idiom of [SettingsService.engineBaseError]. The raw detail
      // rides along in brackets, the way the rest of the app keeps it.
      if (mounted) {
        setState(
          () => _status =
              'That file could not be attached. Check it is an image this '
              'device can open (PNG, JPG or WebP), then pick it again '
              '($e).',
        );
      }
    }
  }

  /// Attach a screenshot the run already saved. This is the useful one: the
  /// engine wrote the exact frame it was looking at when it got stuck.
  Future<void> _attachScreenshot() async {
    List<Map<String, dynamic>> shots;
    try {
      shots = await _engine().shots();
    } catch (e) {
      if (mounted) {
        setState(() => _status = AutopilotService.startHint);
      }
      return;
    }
    if (!mounted) return;
    if (shots.isEmpty) {
      setState(
        () => _status =
            'No evidence screenshots yet - run a build first, or attach an '
            'image file of your own.',
      );
      return;
    }
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => ListView.builder(
        itemCount: shots.length,
        itemBuilder: (context, index) {
          final shot = shots[index];
          final bytes = (shot['bytes'] as num?)?.toInt() ?? 0;
          return ListTile(
            dense: true,
            leading: const Icon(Icons.image_outlined),
            title: Text(shot['name']?.toString() ?? ''),
            subtitle: Text(
              '${shot['modified'] ?? ''}  ·  ${(bytes / 1024).round()} KB',
            ),
            onTap: () => Navigator.pop(context, shot['name']?.toString()),
          );
        },
      ),
    );
    if (choice == null || choice.isEmpty) return;
    setState(() => _status = 'Loading $choice...');
    final shot = await _engine().shot(choice);
    final encoded = (shot['data'] ?? '').toString();
    if (encoded.isEmpty) {
      if (mounted) {
        setState(
          () => _status =
              'That screenshot could not be read. Run the capture again, '
              'or attach an image file of your own ($choice).',
        );
      }
      return;
    }
    final result = await _chat!.persistImage(
      bytes: base64Decode(encoded),
      name: choice,
      mimeType: 'image/png',
    );
    if (!mounted) return;
    setState(() {
      if (result.ok) {
        _pending = [..._pending, result.image!];
        _status = '';
      } else {
        _status = result.error;
      }
    });
  }

  Future<void> _pasteText() async {
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final text = (data?.text ?? '').trim();
      if (text.isEmpty) {
        if (mounted) {
          setState(
            () => _status =
                'The clipboard has no text. (Image paste needs a clipboard '
                'plugin this app does not ship; save the screenshot and use '
                'the image button instead.)',
          );
        }
        return;
      }
      if (!mounted) return;
      setState(() {
        _input.text = _input.text.isEmpty ? text : '${_input.text}\n$text';
        _status = '';
      });
    } catch (e) {
      if (mounted) {
        setState(
          () => _status =
              'The clipboard could not be read. Copy the text again, or '
              'type it into the box by hand ($e).',
        );
      }
    }
  }

  String _mimeFor(String name) {
    final lower = name.toLowerCase();
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'image/jpeg';
    if (lower.endsWith('.webp')) return 'image/webp';
    if (lower.endsWith('.gif')) return 'image/gif';
    return 'image/png';
  }

  // --- approving an action ----------------------------------------------

  Future<void> _runAction(int messageIndex, int actionIndex) async {
    final message = _messages[messageIndex];
    final action = message.actions[actionIndex];
    final mem = _memory;
    setState(() => _busy = true);
    String outcome;
    try {
      switch (action.kind) {
        case 'save_rule':
          final rule = (action.payload['rule'] ?? '').toString().trim();
          if (mem == null || !mem.ready) {
            outcome = 'Memory is not ready, so nothing was saved.';
            break;
          }
          if (rule.isEmpty) {
            outcome = 'That rule was empty.';
            break;
          }
          final targets = (action.payload['targets'] ?? 'all')
              .toString()
              .trim();
          await mem.addRule(rule, targets: targets.isEmpty ? 'all' : targets);
          outcome = 'Rule saved - the planner will use it from now on.';
          break;
        case 'save_preference':
          final key = (action.payload['key'] ?? '').toString().trim();
          if (mem == null || !mem.ready) {
            outcome = 'Memory is not ready, so nothing was saved.';
            break;
          }
          if (key.isEmpty) {
            outcome = 'That preference had no name.';
            break;
          }
          await mem.setPref(key, (action.payload['value'] ?? '').toString());
          outcome = 'Preference saved.';
          break;
        case 'paste_cli':
        case 'config_pcs':
          outcome = await _startSidecarFix(action);
          // A change that was accepted is recorded as a structured
          // transaction BEFORE anything else can happen, so "undo that" later
          // has an exact answer instead of a guess.
          if (!outcome.toLowerCase().startsWith('failed') &&
              !outcome.toLowerCase().startsWith('nothing')) {
            await _recordChanges(action);
          }
          break;
        case 'run_control':
          outcome = await _runControl(action);
          break;
        case 'pkt_fix':
          outcome = await _applyPktFix(action);
          break;
        case 'pkt_undo':
          outcome = await _undoPktFix(action);
          break;
        case 'pkt_scan':
          final scanPath = '${action.payload['path'] ?? ''}';
          if (scanPath.isEmpty) {
            outcome = 'That card has no file path.';
            break;
          }
          await _scanPkt(scanPath, '${action.payload['name'] ?? scanPath}');
          outcome = 'Re-analyzed.';
          break;
        case 'pkt_open':
          final openPath = '${action.payload['path'] ?? ''}';
          if (openPath.isEmpty) {
            outcome = 'That card has no file path.';
            break;
          }
          // Smart route: Packet Tracer when the machine has it, the
          // built-in viewer when it does not - so the card works honestly
          // on machines the label could not know about when it was written.
          final openResult = await _openPktArtifact(openPath);
          outcome = openResult.message;
          break;
        case 'pkt_export':
          outcome = await _exportBuiltPkt(action);
          break;
        case 'layout_preview':
          final opened = await _previewLayout(
            '${action.payload['style'] ?? ''}',
          );
          outcome = opened ? '' : 'There is no plan to preview yet.';
          break;
        case 'pkt_generate':
          await _buildPktFromPlan(action);
          outcome = '';
          break;
        case 'pkt_edit':
          final target = '${action.payload['path'] ?? _artifactPath}';
          if (target.trim().isEmpty) {
            outcome = 'That card has no file to edit.';
            break;
          }
          if (_artifactPath.trim().isNotEmpty &&
              !_samePath(target, _artifactPath)) {
            outcome =
                'That file is not the one this conversation produced, so I am '
                'not overwriting it.';
            break;
          }
          await _editPktInPlace(target);
          outcome = '';
          break;
        case 'ledger':
          outcome = await _showLedger();
          break;
        case 'open_project':
          final project = (action.payload['project'] ?? '').toString().trim();
          if (project.isEmpty) {
            outcome = 'No project name in that action.';
            break;
          }
          widget.onOpenProject?.call(project);
          outcome = 'Opened $project for review.';
          break;
        case 'check_plan':
          // Read-only: the same validator a build runs, on the plan this
          // conversation holds. Nothing is changed here.
          final checkedPlan = _lastIntent;
          if (checkedPlan == null || checkedPlan.nodes.isEmpty) {
            outcome = 'No plan is on the table yet.';
            break;
          }
          final findings = ValidatorService.validate(
            checkedPlan,
            target: _target,
          );
          if (!mounted) {
            outcome = '';
            break;
          }
          await showDialog<void>(
            context: context,
            builder: (dialogContext) => AlertDialog(
              title: Text(
                findings.isEmpty
                    ? 'The plan is clean'
                    : '${findings.length} finding(s)',
              ),
              content: SingleChildScrollView(
                child: SelectableText(
                  findings.isEmpty
                      ? 'The validator found nothing to fix in '
                            '"${checkedPlan.projectName}".'
                      : findings
                            .map((i) => '[${i.severity}] ${i.message}')
                            .join('\n'),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: const Text('Done'),
                ),
              ],
            ),
          );
          outcome = findings.isEmpty
              ? 'Checked the plan: clean, nothing to fix.'
              : 'Checked the plan: ${findings.length} finding(s) shown.';
          break;
        default:
          outcome = 'Unsupported action: ${action.kind}';
      }
    } catch (e) {
      outcome = 'Failed: ${e.toString().replaceFirst('Exception: ', '')}';
    }

    if (!mounted) return;
    // A failed action is NOT done. Marking it executed left a green "Done" on a
    // card whose work never happened, and removed the only way to try again.
    final failed =
        outcome.isEmpty ||
        outcome.toLowerCase().startsWith('failed') ||
        outcome.toLowerCase().startsWith('unsupported') ||
        outcome.toLowerCase().contains('not ready') ||
        outcome.toLowerCase().startsWith('nothing');
    setState(() {
      _busy = false;
      _status = outcome;
      if (failed) return;
      final executed = [...message.executed, actionIndex.toString()];
      final updated = message.copyWith(executed: executed);
      _messages = [..._messages];
      _messages[messageIndex] = updated;
    });
    if (!failed && mem != null && mem.ready && message.id != null) {
      try {
        await mem.updateChat(message.id!, _messages[messageIndex]);
      } catch (_) {}
    }
  }

  /// CLI / desktop corrections go through the same verified path as any other
  /// fix run: `mode: fixes` re-verifies on screen and reports honestly.
  Future<String> _startSidecarFix(ChatAction action) async {
    final svc = _engine();
    if (!await svc.healthy) return AutopilotService.startHint;
    final steps = <Map<String, dynamic>>[];
    if (action.kind == 'paste_cli') {
      final raw = (action.payload['configs'] as Map?) ?? const {};
      final configs = <String, String>{};
      raw.forEach((key, value) {
        final device = key.toString().trim();
        final body = value.toString().trim();
        if (device.isNotEmpty && body.isNotEmpty) configs[device] = body;
      });
      if (configs.isEmpty) return 'Nothing to type - the action had no CLI.';
      steps.add({
        'action': 'paste_cli',
        'configs': configs,
        'typing_delay_ms': 25,
      });
    } else {
      final raw = (action.payload['pcs'] as Map?) ?? const {};
      final pcs = <String, Map<String, String>>{};
      raw.forEach((key, value) {
        if (value is! Map) return;
        final device = key.toString().trim();
        final ip = (value['ip'] ?? '').toString().trim();
        if (device.isEmpty || ip.isEmpty) return;
        pcs[device] = {
          'ip': ip,
          'mask': (value['mask'] ?? '255.255.255.0').toString().trim(),
          'gw': (value['gw'] ?? '').toString().trim(),
        };
      });
      if (pcs.isEmpty) return 'Nothing to set - the action had no valid IPs.';
      steps.add({'action': 'config_pcs', 'pcs': pcs});
    }
    await svc.start({
      'project': _project.text.trim(),
      'steps': steps,
      'mode': 'fixes',
    });
    return 'Started a fix run. It verifies on screen and reports what it '
        'could not prove - watch the Detail tab, and use PAUSE/STOP here.';
  }

  /// Write what this action changed into the change log: one row per field,
  /// with the old value read out of the plan the app itself compiled.
  ///
  /// The old value is the important half. It comes from the plan's addressing
  /// (real data), not from the model's prose, which is what makes a later
  /// "undo that" a lookup rather than a recollection.
  Future<void> _recordChanges(ChatAction action) async {
    final mem = _memory;
    if (mem == null || !mem.ready) return;
    final wanted = <_PendingChange>[];

    if (action.kind == 'paste_cli') {
      final configs = (action.payload['configs'] as Map?) ?? const {};
      configs.forEach((key, value) {
        final device = key.toString().trim();
        var iface = '';
        for (final rawLine in value.toString().split('\n')) {
          final line = rawLine.trim();
          final ifMatch = RegExp(
            r'^interface\s+(\S+)',
            caseSensitive: false,
          ).firstMatch(line);
          if (ifMatch != null) {
            iface = ifMatch.group(1)!;
            continue;
          }
          final ipMatch = RegExp(
            r'^ip address\s+(\S+)\s+(\S+)',
            caseSensitive: false,
          ).firstMatch(line);
          if (ipMatch != null) {
            wanted.add(
              _PendingChange(
                device: device,
                interface: iface,
                field: 'ipAddress',
                newValue: '${ipMatch.group(1)}/${_prefixOf(ipMatch.group(2)!)}',
              ),
            );
            continue;
          }
          final gwMatch = RegExp(
            r'^ip default-gateway\s+(\S+)',
            caseSensitive: false,
          ).firstMatch(line);
          if (gwMatch != null) {
            wanted.add(
              _PendingChange(
                device: device,
                interface: iface,
                field: 'defaultGateway',
                newValue: gwMatch.group(1)!,
              ),
            );
          }
        }
      });
    } else {
      final pcs = (action.payload['pcs'] as Map?) ?? const {};
      pcs.forEach((key, value) {
        if (value is! Map) return;
        final device = key.toString().trim();
        final ip = (value['ip'] ?? '').toString().trim();
        final mask = (value['mask'] ?? '').toString().trim();
        if (ip.isNotEmpty) {
          wanted.add(
            _PendingChange(
              device: device,
              interface: 'f0',
              field: 'ipAddress',
              newValue: mask.isEmpty ? ip : '$ip/${_prefixOf(mask)}',
            ),
          );
        }
        final gw = (value['gw'] ?? '').toString().trim();
        if (gw.isNotEmpty) {
          wanted.add(
            _PendingChange(
              device: device,
              interface: 'f0',
              field: 'defaultGateway',
              newValue: gw,
            ),
          );
        }
      });
    }

    var wrote = 0;
    for (final change in wanted) {
      try {
        await mem.logChange(
          conversation: _conversation,
          device: change.device,
          interface: change.interface,
          field: change.field,
          oldValue: _oldValueFor(change),
          newValue: change.newValue,
          source: 'chat:${action.kind}',
        );
        wrote++;
      } catch (_) {}
    }
    if (wrote > 0) _state.withChanges(await _changesFor());
  }

  /// The value in the plan the app compiled, or '' when it never knew one.
  String _oldValueFor(_PendingChange change) {
    final intent = _lastIntent;
    if (intent == null) return '';
    for (final addr in intent.addressing) {
      if (addr.node.toLowerCase() != change.device.toLowerCase()) continue;
      if (change.interface.isNotEmpty &&
          addr.iface.toLowerCase() != change.interface.toLowerCase()) {
        continue;
      }
      if (change.field == 'ipAddress') return addr.ipCidr;
      if (change.field == 'defaultGateway') {
        final octets = addr.ipCidr.split('/').first.split('.');
        if (octets.length == 4) {
          return '${octets[0]}.${octets[1]}.${octets[2]}.1';
        }
      }
    }
    return '';
  }

  Future<List<Map<String, dynamic>>> _changesFor() async {
    final mem = _memory;
    if (mem == null || !mem.ready) return const [];
    try {
      return await mem.recentChanges(conversation: _conversation, limit: 30);
    } catch (_) {
      return const [];
    }
  }

  /// "Undo that" / "undo the change to Router1" - answered from the change
  /// log, never from the model.
  ///
  /// This is the deterministic half of undo: the app looks up the exact
  /// transaction (device, interface, field, old value) and offers the reverse
  /// as a normal approvable action. The model is not asked which value it
  /// typed earlier, because it cannot know.
  Future<bool> _handleUndo(String text) async {
    if (!RegExp(r'\bundo\b', caseSensitive: false).hasMatch(text)) {
      return false;
    }
    final mem = _memory;
    if (mem == null || !mem.ready) return false;
    final devices = SessionState.devicesIn(text);
    final device = devices.isEmpty ? '' : devices.first;
    final change = await mem.lastChange(
      conversation: _conversation,
      device: device,
    );
    if (change == null) {
      _appendSystem(
        device.isEmpty
            ? 'I have no recorded change to undo in this conversation. I keep '
                  'an exact log of what I changed, so I will not guess at one.'
            : 'I have no recorded change to $device in this conversation.',
      );
      return true;
    }
    final target = (change['device'] ?? '').toString();
    final iface = (change['interface'] ?? '').toString();
    final field = (change['field'] ?? '').toString();
    final oldValue = (change['oldValue'] ?? '').toString();
    final newValue = (change['newValue'] ?? '').toString();
    if (oldValue.trim().isEmpty) {
      _appendSystem(
        'I changed $target $iface $field to "$newValue", but I never had a '
        'previous value for it - so there is nothing to restore. Say what it '
        'should be and I will set it.',
      );
      return true;
    }

    final action = _revertAction(target, iface, field, oldValue);
    final summary =
        '$target${iface.isEmpty ? '' : ' $iface'} $field: '
        '"$newValue" -> "$oldValue"';
    final turn = ChatMessage(
      role: 'model',
      text:
          'Undoing the change I made (change '
          '#${change['actionId']}, recorded ${_stamp((change['createdAt'] ?? '').toString())}):\n'
          '\n'
          '- device: $target\n'
          '- interface: ${iface.isEmpty ? '(none)' : iface}\n'
          '- field: $field\n'
          '- current value: "$newValue"\n'
          '- value I will restore: "$oldValue"\n'
          '\n'
          'That is the exact transaction from the change log, not a '
          'reconstruction. Approve the card and it goes through the same '
          'verified path as any other fix.',
      actions: [
        ChatAction(
          kind: action.kind,
          payload: action.payload,
          summary: 'Undo: $summary',
        ),
      ],
      createdAt: DateTime.now().toIso8601String(),
    );
    setState(() => _messages = [..._messages, turn]);
    _jumpToEnd();
    try {
      await mem.logChat(turn, conversation: _conversation);
    } catch (_) {}
    return true;
  }

  /// Park what a repair pass would teach, against the plan it repaired.
  ///
  /// This records nothing a plan can read: the rules sit next to the plan's
  /// fingerprint until a build of that plan verifies, and are dropped if it
  /// fails. Failures here are swallowed on purpose - a memory hiccup must not
  /// cost the user the answer they asked for.
  Future<void> _parkRepairLearning(
    NetworkIntent plan,
    List<RepairFix> fixes,
  ) async {
    final mem = _memory;
    if (mem == null || !mem.ready || fixes.isEmpty) return;
    try {
      await mem.noteRepairedPlan(
        plan: plan,
        fixes: fixes,
        target: _target,
      );
    } catch (_) {}
  }

  /// "fix the plan", "fix these findings", "can you fix it" - run the
  /// deterministic repair pass over the standing plan and answer with what
  /// changed and a fresh build card.
  ///
  /// This is the missing half of the build card's refusal: the card names the
  /// findings that would be baked into the .pkt, and until this existed there
  /// was no way to act on them from the chat at all - saying "fix the plan"
  /// got the same plan described back, and the disabled button stayed
  /// disabled. Returns false (so the normal turn continues) when there is no
  /// plan to repair yet or the message is not a repair request.
  Future<bool> _handlePlanRepair(String text) async {
    if (!OfflineAssistantService.looksLikeRepairRequest(text)) return false;
    final plan = _lastIntent;
    if (plan == null || plan.nodes.isEmpty) return false;
    _revealFinish?.call();
    // Keep the pre-repair plan: the answer says what changed, and the next
    // turn still needs to know which lab the user was looking at.
    _previousIntent = plan;
    // "fix every finding you got then build" is ONE request: the repair runs,
    // and when it clears the plan the build follows without a second click.
    // The reply's wording is told about the build half, so it never asks for
    // the click the user already gave.
    final wantsBuild = OfflineAssistantService.asksToBuildAfterRepair(text);
    final reply = OfflineAssistantService.fixPlan(
      plan: plan,
      target: _target,
      suggestions: PlannerSuggestionsService.forIntent(plan, target: _target),
      andBuild: wantsBuild,
    );
    final repaired = reply.repairedPlan;
    if (repaired != null) {
      _lastIntent = repaired;
      _state.withIntentJson(jsonEncode(repaired.toJson(includeSecrets: false)));
      await _parkRepairLearning(repaired, reply.repairedFixes);
    }
    final stamp = DateTime.now().toIso8601String();
    final ask = ChatMessage(role: 'user', text: text, createdAt: stamp);
    final turn = ChatMessage(
      role: 'model',
      text: reply.text,
      createdAt: stamp,
      // A fresh card, stamped with the plan that stands NOW. This is what
      // replaces a refused card: the user never has to retype the brief or
      // ask a second time to get a buildable plan.
      actions: repaired == null || repaired.nodes.isEmpty
          ? const <ChatAction>[]
          : <ChatAction>[_buildCardFor(repaired)],
    );
    if (!mounted) return true;
    setState(() {
      _messages = [..._messages, ask, turn];
      _status = '';
      _quickReplies = reply.quickReplies;
    });
    _jumpToEnd();
    final mem = _memory;
    if (mem != null && mem.ready) {
      try {
        await mem.logChat(ask, conversation: _conversation);
        await mem.logChat(turn, conversation: _conversation);
        await mem.setSessionState(_conversation, _state.encode());
      } catch (_) {}
    }
    // The build half of "fix these then build". Only when the repair actually
    // left nothing blocking: a build that would ship the findings the answer
    // just listed is exactly the dead end this path exists to remove.
    if (wantsBuild &&
        repaired != null &&
        repaired.nodes.isNotEmpty &&
        OfflineAssistantService.blockingFindings(
          repaired,
          target: _target,
        ).isEmpty) {
      await _buildPktFromPlan(_buildCardFor(repaired));
    }
    return true;
  }

  /// The reverse of one recorded field change, as a normal approvable action.
  ChatAction _revertAction(
    String device,
    String iface,
    String field,
    String oldValue,
  ) {
    if (field == 'ipAddress') {
      final parts = oldValue.split('/');
      final ip = parts.first;
      final mask = parts.length > 1 ? _maskOf(parts[1]) : '255.255.255.0';
      return ChatAction(
        kind: 'paste_cli',
        payload: {
          'configs': {
            device:
                '${iface.isEmpty ? '' : 'interface $iface\n'} ip address $ip $mask',
          },
        },
      );
    }
    if (field == 'defaultGateway') {
      final current = _lastIntent?.addressing.firstWhere(
        (a) =>
            a.node.toLowerCase() == device.toLowerCase() &&
            (iface.isEmpty || a.iface.toLowerCase() == iface.toLowerCase()),
        orElse: () => const InterfaceAddr(node: '', iface: '', ipCidr: ''),
      );
      return ChatAction(
        kind: 'config_pcs',
        payload: {
          'pcs': {
            device: {
              'ip': current == null || current.ipCidr.isEmpty
                  ? ''
                  : current.ipCidr.split('/').first,
              'mask': current == null || current.ipCidr.isEmpty
                  ? '255.255.255.0'
                  : _maskOf(
                      current.ipCidr.contains('/')
                          ? current.ipCidr.split('/').last
                          : '24',
                    ),
              'gw': oldValue,
            },
          },
        },
      );
    }
    return ChatAction(
      kind: 'paste_cli',
      payload: {
        'configs': {device: '$field $oldValue'},
      },
    );
  }

  static String _prefixOf(String mask) {
    final parts = mask.split('.');
    if (parts.length != 4) return mask;
    var bits = 0;
    for (final part in parts) {
      final octet = int.tryParse(part) ?? 0;
      for (var i = 7; i >= 0; i--) {
        if ((octet >> i) & 1 == 1) {
          bits++;
        }
      }
    }
    return '$bits';
  }

  static String _maskOf(String prefix) {
    final bits = int.tryParse(prefix.trim());
    if (bits == null || bits < 0 || bits > 32) return '255.255.255.0';
    var value = bits == 0 ? 0 : (0xFFFFFFFF << (32 - bits)) & 0xFFFFFFFF;
    return '${(value >> 24) & 0xFF}.${(value >> 16) & 0xFF}.'
        '${(value >> 8) & 0xFF}.${value & 0xFF}';
  }

  /// Name the conversation from its first exchange, once. The user can rename
  /// it afterwards, and a manual name is never overwritten.
  Future<void> _autoTitleFirstTurn(MemoryService mem) async {
    final meta = await mem.conversationMeta(_conversation);
    if (meta == null) return;
    if ((meta['title'] ?? '').toString().trim().isNotEmpty) return;
    final firstUser = _messages.firstWhere(
      (m) => m.isUser && m.text.trim().isNotEmpty,
      orElse: () => const ChatMessage(role: 'user', text: ''),
    );
    if (firstUser.text.trim().isEmpty) return;
    final title = ConversationTitles.generate(firstUser.text);
    if (title.trim().isEmpty || title == 'New chat') return;
    await mem.renameConversation(_conversation, title);
  }

  Future<String> _runControl(ChatAction action) async {
    final svc = _engine();
    if (!await svc.healthy) return AutopilotService.startHint;
    final command = (action.payload['command'] ?? 'pause')
        .toString()
        .toLowerCase();
    switch (command) {
      case 'resume':
        await svc.resume();
        return 'Resume requested.';
      case 'stop':
        await svc.stop();
        return 'Stop requested.';
      default:
        await svc.pause();
        return 'Pause requested - the run parks at its next safe boundary.';
    }
  }

  // --- build -------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final settings = _settings;
    if (settings != null) _syncWindow(settings);
    // Android's back gesture closes whatever panel is riding over the chat
    // before it leaves the screen: a user who opened the conversation list
    // should not have to discover the barrier tap to get out.
    final width = MediaQuery.sizeOf(context).width;
    final overlayOpen =
        (width < sidebarBreakpoint && _sidebarOpen) ||
        (width < inspectorBreakpoint && _inspectorOpen);
    return PopScope(
      canPop: !overlayOpen,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop || !overlayOpen) return;
        setState(() {
          _sidebarOpen = false;
          _inspectorOpen = false;
        });
      },
      child: _conversationLayout(),
    );
  }

  /// Where the conversation list and the inspector are wide enough to be
  /// columns rather than overlays. Named because the back-gesture handling
  /// above has to agree with the layout below.
  static const double sidebarBreakpoint = 980;
  static const double inspectorBreakpoint = 1240;

  Widget _conversationLayout() {
    // Conversation first: the transcript takes every pixel that the two side
    // panels are not using, the list is centred on a reading measure, and
    // neither panel is ever allowed to be the reason the chat is cramped.
    //
    //  * wide window  - the conversation list is a column, the inspector is a
    //    column, and both collapse to give the chat the width back;
    //  * narrow window - the list slides over the chat instead of squeezing
    //    it, and the inspector does the same from the other side.
    return LayoutBuilder(
      builder: (context, constraints) {
        final roomForSidebar = constraints.maxWidth >= sidebarBreakpoint;
        final roomForInspector = constraints.maxWidth >= inspectorBreakpoint;
        if (roomForSidebar && !_sidebarAutoOpened) {
          _sidebarAutoOpened = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && !_sidebarTouched) {
              setState(() => _sidebarOpen = true);
            }
          });
        }
        final chat = _chatColumn(roomForSidebar);
        final sidebar = ConversationSidebar(
          conversations: _conversations,
          activeId: _conversation,
          query: _conversationQuery,
          busy: _busy,
          project: _project.text.trim(),
          onNewChat: _startNewChat,
          onOpen: _openConversation,
          onRename: (id, title) => _renameConversation(id, title),
          onDelete: _deleteConversation,
          onSearch: (query) {
            _conversationQuery = query;
            _refreshConversations();
          },
          onSettings: () => Scaffold.maybeOf(context)?.openDrawer(),
          onCollapse: () {
            _sidebarTouched = true;
            setState(() => _sidebarOpen = false);
          },
        );

        final body = Row(
          children: [
            if (roomForSidebar && _sidebarOpen) sidebar,
            if (roomForSidebar && !_sidebarOpen)
              CollapsedConversationRail(
                onExpand: () {
                  _sidebarTouched = true;
                  setState(() => _sidebarOpen = true);
                },
                onNewChat: _startNewChat,
                onSettings: () => Scaffold.maybeOf(context)?.openDrawer(),
              ),
            Expanded(child: chat),
            if (roomForInspector && _inspectorOpen)
              NetworkInspector(
                project: _project.text.trim(),
                intent: _lastIntent,
                state: _state,
                changes: _changes,
                onClose: () => setState(() => _inspectorOpen = false),
              ),
          ],
        );

        // Narrow windows: the panels ride over the conversation and dismiss
        // with a tap, which keeps the chat the primary surface at any size.
        if (!roomForSidebar && _sidebarOpen) {
          return Stack(
            children: [
              body,
              Positioned.fill(
                child: GestureDetector(
                  onTap: () => setState(() => _sidebarOpen = false),
                  child: Container(color: Colors.black.withValues(alpha: 0.35)),
                ),
              ),
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                child: Material(child: sidebar),
              ),
            ],
          );
        }
        if (!roomForInspector && _inspectorOpen) {
          return Stack(
            children: [
              body,
              Positioned.fill(
                child: GestureDetector(
                  onTap: () => setState(() => _inspectorOpen = false),
                  child: Container(color: Colors.black.withValues(alpha: 0.35)),
                ),
              ),
              Positioned(
                right: 0,
                top: 0,
                bottom: 0,
                child: Material(
                  child: NetworkInspector(
                    project: _project.text.trim(),
                    intent: _lastIntent,
                    state: _state,
                    changes: _changes,
                    onClose: () => setState(() => _inspectorOpen = false),
                  ),
                ),
              ),
            ],
          );
        }
        return body;
      },
    );
  }

  /// The conversation itself: header, transcript, status, composer.
  Widget _chatColumn(bool roomForSidebar) {
    // The composer travels. On an empty conversation it sits in the middle of
    // the page under the greeting, so the first thing the eye lands on is the
    // thing the user is about to use; once there is a transcript it pins to
    // the bottom edge where a chat box belongs. Everything else about this
    // column is the page: a title bar, the conversation, and the box.
    final empty = _messages.isEmpty;
    return Column(
      children: [
        _conversationHeader(roomForSidebar),
        if (_engineReachable == false) _engineBanner(),
        Expanded(
          child: empty
              ? _openingScreen()
              : Stack(
                  children: [
                    Semantics(
                      container: true,
                      label: 'Conversation with the NetBuilder assistant',
                      child: ListView.builder(
                        controller: _scroll,
                        padding: const EdgeInsets.fromLTRB(12, 16, 12, 16),
                        // The typing bubble is for the wait before an answer
                        // starts. Once the answer is streaming in, its own
                        // bubble is already there and a second one would be a
                        // placeholder under a growing message. The activity
                        // panel rides after the last turn, where the work it
                        // describes just happened.
                        itemCount:
                            _messages.length +
                            (_waiting ? 1 : 0) +
                            (_activity.isNotEmpty ? 1 : 0),
                        itemBuilder: (context, index) {
                          if (index == _messages.length && _waiting) {
                            return _centred(const _TypingBubble());
                          }
                          if (index >= _messages.length) {
                            return _centred(
                              ActivityPanel(
                                entries: _activity,
                                expanded: _activityOpen,
                                working: _busy,
                                problemCount: _state.confirmedFindings.isEmpty
                                    ? null
                                    : _state.confirmedFindings.length,
                                onToggle: () => setState(
                                  () => _activityOpen = !_activityOpen,
                                ),
                              ),
                            );
                          }
                          return _centred(_bubble(index));
                        },
                      ),
                    ),
                    if (!_atBottom && _messages.isNotEmpty)
                      Positioned(
                        right: AppTheme.s16,
                        bottom: AppTheme.s12,
                        child: _JumpToLatest(
                          unseen: _unseen,
                          onTap: () => _jumpToEnd(),
                        ),
                      ),
                  ],
                ),
        ),
        if (_status.isNotEmpty)
          Container(
            width: double.infinity,
            color: AppPalette.panelAlt(Theme.of(context).colorScheme),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(_status, style: const TextStyle(fontSize: 12)),
                ),
                // RETRY: a failed turn keeps the typed message, so this
                // re-sends it without any retyping.
                if (_failedText != null)
                  TextButton(
                    onPressed: _busy ? null : _retry,
                    child: const Text('Retry'),
                  ),
              ],
            ),
          ),
        if (_busy) const LinearProgressIndicator(minHeight: 2),
        // The token counter used to live here. It is a debugging readout, and
        // a permanent strip of it between the transcript and the box made the
        // chat look like a developer console. Its full report is still one
        // tap away in the tools sheet.
        if (!empty) _composer(),
      ],
    );
  }

  /// The opening screen: a greeting, a few things worth saying, and the box
  /// to say them in.
  ///
  /// The composer is ANCHORED to the bottom, the way every chat app anchors
  /// it: an input that floats mid-screen with dead space underneath reads as
  /// broken, and its position would jump once the first answer arrives. The
  /// greeting and the suggestion chips flex above it - scrolling inside
  /// themselves when the window is too short for them - so on a landscape
  /// phone or with large system text the box never leaves the window.
  Widget _openingScreen() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppTheme.s16,
        AppTheme.s16,
        AppTheme.s16,
        AppTheme.s8,
      ),
      child: Column(
        // Stretch, not centre: the composer holds an Expanded text field and
        // needs a BOUNDED width. Handed loose constraints it collapses to its
        // minimum and overflows the row by 35px on a 360px phone.
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // One flexible gap ABOVE the group only: the composer sits at the
          // bottom edge (where a chat input belongs), the greeting floats
          // between the top and it, and on a short window the spacer
          // collapses and the greeting scrolls instead of pushing the box
          // off screen.
          const Spacer(),
          Flexible(
            child: SingleChildScrollView(
              child: _welcomeHead,
            ),
          ),
          const SizedBox(height: AppTheme.s16),
          _composer(),
        ],
      ),
    );
  }

  Widget get _welcomeHead => ChatWelcome(
    embedded: true,
    // A raw storage id ("chat 0:1228") is not a project name: the welcome
    // line only names REAL projects, otherwise it reads machine-speak.
    hasProject: _project.text.trim().isNotEmpty &&
        _project.text.trim() != 'default' &&
        !ConversationTitles.isRawId(_project.text.trim()),
    project: ConversationTitles.display(_project.text.trim()),
    onSuggestion: (suggestion) {
      // A chip writes the question into the box (and submits it) rather than
      // sending a canned string: the user keeps the words and can edit them
      // first.
      _input.text = _suggestionPrompt(suggestion);
      _input.selection = TextSelection.collapsed(offset: _input.text.length);
      _composerFocus.requestFocus();
      if (suggestion != 'Create a network' &&
          suggestion != 'Open a .pkt project' &&
          suggestion != 'Analyze a network') {
        _send();
      }
    },
  );

  /// Everything in the transcript shares one centred reading measure, so a
  /// maximised window does not stretch a sentence across 2,000 pixels.
  Widget _centred(Widget child) => Align(
    alignment: Alignment.topCenter,
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 860),
      child: child,
    ),
  );

  static String _suggestionPrompt(String suggestion) => switch (suggestion) {
    'Analyze a network' => 'Analyze my network and tell me what is wrong.',
    'Troubleshoot connectivity' => 'Can PC1 reach Server0? If not, why?',
    'Open a .pkt project' => 'Open my saved .pkt project and summarize it.',
    'Check a configuration' => 'Check this configuration for mistakes:\n\n',
    'Create a network' =>
      'Build a small office network: 2 routers, 2 switches and 4 PCs.',
    _ => suggestion,
  };

  /// Switch to another conversation: its transcript, its summary and its
  /// structured state all come back with it.
  Future<void> _openConversation(String id) async {
    if (id == _conversation) return;
    if (_busy) {
      // Switching mid-answer would let the in-flight turn finish into the
      // conversation the user just opened, because the stream writes through
      // the live state. Stop first; the answer is kept.
      if (mounted) {
        setState(() {
          _status = 'Stop the current answer before switching conversations.';
        });
      }
      return;
    }
    setState(() {
      _project.text = id;
      _resetConversationState();
    });
    _settings?.setLastProject(id);
    await _load();
    if (!mounted) return;
    setState(() => _conversationQuery = '');
  }

  Future<void> _renameConversation(String id, String title) async {
    if (_busy) return;
    final mem = _memory;
    if (mem == null || !mem.ready) return;
    try {
      await mem.renameConversation(id, title);
    } catch (_) {}
    await _refreshConversations();
  }

  Future<void> _deleteConversation(String id) async {
    if (_busy) return;
    final mem = _memory;
    if (mem == null || !mem.ready) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete this conversation?'),
        content: const Text(
          'The transcript, its summary and its change log are removed. Saved '
          'rules and preferences are not touched.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await mem.clearChat(conversation: id);
    } catch (_) {}
    if (id == _conversation) {
      setState(_resetConversationState);
    }
    await _refreshConversations();
  }

  /// The conversation's own bar: which chat this is, the network it is about,
  /// how much is in it, and the controls that belong to the conversation
  /// rather than to the settings.
  ///
  /// This is what makes the chat feel like a chat app rather than one long
  /// scroll: a name, the network it concerns (so the same .pkt never has to be
  /// selected twice), a size, and the panels.
  Widget _conversationHeader(bool roomForSidebar) {
    final theme = Theme.of(context);
    // THE HEADER IS NOT A TOOLBAR. It exists to say which conversation this
    // is and to open a new one. Everything else that used to live here - the
    // model's status tag, the project chip, the message count, the clear
    // button - is state the user came here to talk, not to read. It is all
    // still reachable (the tools sheet, the sidebar, the inspector), and
    // what is left is the one bar a chat needs.
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
      child: Row(
        children: [
          // The conversation list. On a wide window it collapses to a rail
          // (and this button brings it back); on a narrow one it slides
          // over the chat, so this is the only way in.
          if (!roomForSidebar || !_sidebarOpen)
            IconButton(
              tooltip: 'Show the conversation list',
              visualDensity: VisualDensity.compact,
              // Not a hamburger: the app bar's drawer button already owns
              // that icon, and two of them side by side read as one thing.
              icon: const Icon(Icons.view_sidebar_outlined, size: 18),
              onPressed: () {
                _sidebarTouched = true;
                setState(() => _sidebarOpen = true);
              },
            )
          else
            Icon(
              Icons.forum_outlined,
              size: 15,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          const SizedBox(width: AppTheme.s8),
          Flexible(
            child: Text(
              ConversationTitles.display(_conversation),
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleSmall,
            ),
          ),
          const Spacer(),
          // The optional network panel: real topology, addressing and
          // validator findings for the plan on the table. A panel toggle is
          // the one non-essential control worth a permanent place - the
          // panel is the app's second surface, not a detail.
          IconButton(
            tooltip: _inspectorOpen
                ? 'Hide the network inspector'
                : 'Show the network inspector',
            visualDensity: VisualDensity.compact,
            isSelected: _inspectorOpen,
            icon: const Icon(Icons.lan_outlined, size: 18),
            selectedIcon: const Icon(Icons.lan, size: 18),
            onPressed: () => setState(() => _inspectorOpen = !_inspectorOpen),
          ),
          IconButton(
            tooltip: 'Search in this conversation',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.search, size: 18),
            onPressed: _openSearch,
          ),
          IconButton(
            tooltip: 'New chat',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.add_comment_outlined, size: 18),
            onPressed: _busy ? null : _startNewChat,
          ),
        ],
      ),
    );
  }

  /// Open a fresh conversation. The old one keeps its own transcript in
  /// memory and stays in the sidebar, so nothing is lost by starting over.
  Future<void> _startNewChat() async {
    final now = DateTime.now();
    final name =
        'chat ${now.hour}:${now.minute.toString().padLeft(2, '0')}'
        '${now.second.toString().padLeft(2, '0')}';
    setState(() {
      _project.text = name;
      _resetConversationState();
      _unseen = 0;
    });
    await _load();
  }

  /// Search the conversation that is open, and nothing else. The sidebar's
  /// search answers "which chat was that in?"; this one answers "where in
  /// THIS chat was it said" and takes the reader there. Keeping the two
  /// apart is what stops a mixed hit list from being one more place to lose
  /// one's place.
  void _openSearch() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => _ConversationSearch(
        messages: _messages,
        onOpen: (message) {
          Navigator.of(sheetContext).pop();
          _scrollToMessage(message);
        },
      ),
    );
  }

  /// Scroll the transcript to a message, the way a search result asks.
  ///
  /// The transcript is a lazy list: a bubble far off-screen has no context
  /// until it is built. So the jump is estimate-then-correct - a proportional
  /// guess puts the neighbourhood on stage within the builder's cache
  /// window, and [Scrollable.ensureVisible] then lands exactly on the turn.
  /// A bubble that never appears (the list changed while the sheet was
  /// open) just does not scroll: yanking the viewport somewhere else would
  /// be a wrong answer to a tap that named a specific turn.
  void _scrollToMessage(ChatMessage message) {
    final key = GlobalObjectKey(message);
    var attempts = 0;
    void reveal() {
      if (!mounted) return;
      final target = key.currentContext;
      if (target != null) {
        Scrollable.ensureVisible(
          target,
          duration: const Duration(milliseconds: 240),
          curve: Curves.easeOut,
          alignment: 0.05,
        );
        return;
      }
      if (!_scroll.hasClients || ++attempts > 4) return;
      final index = _messages.indexOf(message);
      if (index < 0) return;
      final max = _scroll.position.maxScrollExtent;
      final estimate = max * ((index + 1) / _messages.length);
      // clamp answers a num; the controller wants a double.
      _scroll.jumpTo(estimate.clamp(0.0, max).toDouble());
      WidgetsBinding.instance.addPostFrameCallback((_) => reveal());
    }

    WidgetsBinding.instance.addPostFrameCallback((_) => reveal());
  }


  /// Says plainly that the `.pkt` engine cannot be reached, and offers the
  /// one thing that fixes it.
  ///
  /// Before this, that fact only appeared inside a chat bubble, after the user
  /// had already tried something - which is what made the Android build feel
  /// broken. On a phone the reason is specific and worth naming: the address
  /// has to be the PC, never the phone itself.
  Widget _engineBanner() {
    final address = _settings?.engineBase ?? '';
    final mobile = SettingsService.isMobile;
    final status = EngineStatus.instance;
    // On a phone the engine is optional, not missing: the bundled template
    // library builds the .pkt on this device. That changes the strip from an
    // alarm into a status - and pretending otherwise is what made the
    // Android build feel broken.
    final onDevice = mobile && (_settings?.preferOnDevicePkt ?? true);
    // One compact line: this strip sits between the header and the
    // transcript, and every extra row it takes is a row the transcript does
    // not get on a short window with large text. It is also given a hard
    // height cap with its own scroll: on a 320px phone at 1.5x text this
    // banner alone was tall enough to overflow the whole chat column.
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 132),
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            AppTheme.s10,
            AppTheme.s8,
            AppTheme.s10,
            AppTheme.s4,
          ),
          child: AppBanner(
            dense: true,
            tone: onDevice ? AppTone.info : AppTone.danger,
            icon: onDevice
                ? Icons.phone_android_outlined
                : Icons.cloud_off_outlined,
            message: onDevice
                ? 'No .pkt engine at $address. Builds run on this device - '
                      'planning and .pkt files work without a PC.'
                : mobile
                ? 'No .pkt engine at $address. On a phone the engine runs on '
                      'your PC, so this must be that PC\'s address - not '
                      '127.0.0.1.'
                : 'No .pkt engine at $address. Planning, tools and .pkt files '
                      'all work without it.',
            // The actions wrap: at a phone width this banner must not be the
            // thing that overflows the chat.
            actions: [
              if (_engineStarting)
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else if (status.canStartLocally)
                // Nothing to start on a phone, where the engine is a PC
                // program: the button would be a lie with a spinner.
                TextButton(
                  onPressed: _startEngine,
                  child: const Text('Start engine'),
                ),
              TextButton(
                onPressed: () => Scaffold.maybeOf(context)?.openDrawer(),
                child: const Text('Set address'),
              ),
              TextButton.icon(
                onPressed: status.isBusy ? null : _checkEngine,
                icon: const Icon(Icons.refresh, size: 16),
                label: const Text('Check again'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Ask the engine whether anything answers there. Never assumed - and
  /// answered from [EngineStatus]'s cache, so a missing engine cannot make
  /// the chat feel slow.
  Future<void> _checkEngine() async {
    final ok = await EngineStatus.instance.probe();
    if (!mounted) return;
    setState(() => _engineReachable = ok);
  }

  /// The banner's own "make it work" button: start the engine from here
  /// instead of sending the user to a terminal.
  Future<void> _startEngine() async {
    if (!EngineStatus.instance.canStartLocally) {
      _appendSystem(
        'This device cannot run the .pkt engine - it is a PC program.\n'
        '1. Start the app (or `python sidecar/pt_autopilot.py`) on the PC.\n'
        '2. Find that PC\'s address on your network.\n'
        '3. Set it here: Settings -> Engine address, e.g. '
        'http://192.168.1.20:5005, then press Test.\n'
        'On the Android emulator the host PC answers on 10.0.2.2.',
      );
      return;
    }
    setState(() => _engineStarting = true);
    final ok = await EngineStatus.instance.ensure(force: true);
    if (!mounted) return;
    setState(() {
      _engineStarting = false;
      _engineReachable = ok;
    });
    if (!ok) {
      _appendSystem(
        'I could not start the local engine.\n${EngineStatus.instance.summary}\n'
        'Everything except driving Packet Tracer still works. Open '
        '"Local engine status" from the feature hub for the full report.',
      );
    } else {
      _appendSystem('Local engine is running. Packet Tracer builds are ready.');
    }
  }

  /// The two capture actions, and a way through to everything else.
  ///
  /// Run controls, the ledger, GNS3, live context and the project name are not
  /// touched while chatting, so they live in Settings now; this sheet keeps only
  /// what a person actually reaches for mid-conversation.
  void _openTools() {
    final theme = Theme.of(context);

    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _sheetHeader(theme, 'Capture'),
              ListTile(
                leading: const Icon(Icons.build_circle_outlined),
                title: const Text('Build a .pkt from the current plan'),
                subtitle: const Text(
                  'Offline - no Packet Tracer, no key '
                  'needed',
                ),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _buildCurrentPlan();
                },
              ),
              ListTile(
                leading: const Icon(Icons.router_outlined),
                title: const Text('Analyze a .pkt'),
                subtitle: const Text('Decrypt, audit and propose fixes'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _pickPkt();
                },
              ),
              const Divider(height: 1),
              _sheetHeader(theme, 'On this device'),
              // The phone route. The sidecar needs Python and a reachable
              // PC; on Android neither exists, so the app builds the save
              // itself from a template seed the user imports once.
              ListTile(
                leading: const Icon(Icons.download_outlined),
                title: const Text('Import a seed .pkt'),
                subtitle: Text(
                  _seedHint ?? 'Teach this device which hardware it can build',
                ),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _importSeedPkt();
                },
              ),
              ListTile(
                leading: const Icon(Icons.phone_iphone),
                title: const Text('Build a .pkt on this device'),
                subtitle: const Text(
                  'No PC, no server - writes the file to the app',
                ),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _buildOnDevice();
                },
              ),
              ListTile(
                leading: const Icon(Icons.ios_share_outlined),
                title: const Text('Share the last .pkt'),
                subtitle: Text(
                  _artifactName.isEmpty
                      ? 'Send a built file to a PC or a friend'
                      : _artifactName,
                ),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _shareArtifact();
                },
              ),
              ListTile(
                leading: const Icon(Icons.forum_outlined),
                title: const Text('Share the transcript'),
                subtitle: const Text('This conversation as markdown'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _shareTranscript();
                },
              ),
              const Divider(height: 1),
              _sheetHeader(theme, 'Diagnostics'),
              // The model's state and the token report used to live in the
              // header and above the composer. As permanent furniture they
              // made the chat look like a console; as answers to "why did
              // that happen" they are exactly the right place.
              ListTile(
                leading: const Icon(Icons.psychology_outlined),
                title: Text('AI backend: ${_aiStatus.short}'),
                subtitle: Text(
                  _aiStatus.detail.isEmpty
                      ? 'Running locally.'
                      : _aiStatus.detail,
                ),
              ),
              ListTile(
                leading: const Icon(Icons.memory_outlined),
                title: const Text('Context report'),
                subtitle: const Text(
                  'What the last request carried, and how much of '
                  'the window it used',
                ),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _showContextReport();
                },
              ),
              ListTile(
                leading: const Icon(Icons.delete_sweep_outlined),
                title: const Text('Clear this conversation'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _clearChat();
                },
              ),
              ListTile(
                leading: const Icon(Icons.settings_outlined),
                title: const Text('Settings'),
                subtitle: const Text(
                  'Run controls, ledger, GNS3, live '
                  'context, project, API key, folders',
                ),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  Scaffold.maybeOf(context)?.openDrawer();
                },
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  Widget _sheetHeader(ThemeData theme, String label) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 10, 16, 2),
    child: Align(
      alignment: Alignment.centerLeft,
      child: Text(
        label,
        style: theme.textTheme.labelLarge?.copyWith(
          fontWeight: FontWeight.w700,
        ),
      ),
    ),
  );

  Future<void> _clearChat() async {
    final mem = _memory;
    // The id is captured before the dialog: an empty id means "every
    // conversation" to the store, which is how one chat's Clear button used to
    // delete every transcript, summary and change log in the app.
    final id = _conversation;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear this conversation?'),
        content: Text(
          'This removes the "$id" transcript, its saved summary, its '
          'structured state and its change log. Other conversations, saved '
          'rules and preferences stay. Attachments are left on disk.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (mem != null && mem.ready) {
      try {
        await mem.clearChat(conversation: id);
      } catch (_) {}
    }
    if (!mounted) return;
    setState(_resetConversationState);
    await _refreshConversations();
  }

  /// Fix one slot of the parse from the "Understood" card.
  ///
  /// Tapping a chip asks for the value the user meant, re-reads THIS turn's
  /// words with that value in them, and replaces the standing plan with what
  /// they reparse to. Two things make it worth more than a button:
  ///
  /// * the user never has to re-type English and hope the parser does better
  ///   - the plan is corrected where they can see it;
  /// * every tap is a LABELED training pair (their exact words, what they
  ///   meant), which is what the misparse ledger counts and, at three
  ///   sightings, proposes as a phrasing. Zero ambiguity, because the user
  ///   supplied the label themselves.
  Future<void> _fixSlot({
    required int messageIndex,
    required String slot,
    required String label,
    required String value,
  }) async {
    final intent = _lastIntent;
    if (intent == null || _busy || messageIndex < 0) return;
    // The controller lives INSIDE the dialog: the route is still animating
    // out - and still listening - when showDialog returns, so disposing the
    // controller here broke the very widget that was going away.
    final fixed = await showDialog<String>(
      context: context,
      builder: (_) => _SlotFixDialog(label: label, value: value),
    );
    if (fixed == null || !mounted) return;
    final answer = fixed.trim();
    if (answer.isEmpty || answer == value) return;

    final original = _messages[messageIndex].text;
    final corrected = MisparseLedger.correctedBrief(
      original: original,
      slot: slot,
      value: answer,
      current: intent,
    );
    if (corrected == null || corrected.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'I could not rewrite "$original" with $label $answer, so '
            'nothing was changed. Type the correction instead and I will '
            'read it.',
          ),
        ),
      );
      return;
    }

    final understood = MisparseLedger.briefFromPlan(intent);
    try {
      final outcome = NetworkIntent.followUp(
        previous: _previousIntent,
        previousBrief: _previousBrief,
        brief: corrected,
        parsed: NetworkIntent.parseSimple('chat', corrected),
        project: 'chat',
      );
      _lastIntent = outcome.plan;
      _lastBrief = outcome.brief;
      _brief = DesignBriefService.briefForTurn(
        previous: _brief,
        normalizedText: corrected,
        parsedPlan: outcome.plan,
      ).brief;
      _understoodOk = true;
      _state.withIntentJson(
        jsonEncode(outcome.plan.toJson(includeSecrets: false)),
      );
      _state.briefJson = jsonEncode(_brief.toJson());
    } catch (_) {
      // A fix that cannot be re-parsed changes nothing at all.
      return;
    }
    _slotFixNote = 'Fixed: $answer $label - remembered for "$original".';
    setState(() {});

    final mem = _memory;
    if (mem != null) {
      try {
        await mem.recordMisparse(
          original: original,
          understood: understood,
          corrected: corrected,
          slot: slot,
          source: 'tap',
        );
        await mem.setSessionState(_conversation, _state.encode());
      } catch (_) {
        // The plan on screen is already right; only the lesson is lost.
      }
    }
  }

  /// The "here is exactly what I understood" card: the parse of the
  /// latest user turn as chips - device counts, VLANs, routing, and how
  /// sure the parser is - with the planner's open questions as tappable
  /// chips that write themselves into the composer. Intent made visible
  /// AND correctable: the plan is fixed before it is built, not after.
  Widget _intentUnderstood(int index) {
    final intent = _lastIntent;
    if (intent == null || !_understoodOk) return const SizedBox.shrink();
    // Only under the LATEST user turn - older turns had older plans.
    var lastUser = -1;
    for (var i = _messages.length - 1; i >= 0; i--) {
      if (_messages[i].isUser) {
        lastUser = i;
        break;
      }
    }
    if (index != lastUser) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final counts = <String, int>{};
    for (final n in intent.nodes) {
      counts[n.type] = (counts[n.type] ?? 0) + 1;
    }

    String unit(String type, int n) {
      if (type == 'pc') return n == 1 ? 'PC' : 'PCs';
      if (type == 'wireless') return n == 1 ? 'AP' : 'APs';
      if (type == 'switch') return n == 1 ? 'switch' : 'switches';
      if (type == 'wireless-router') {
        return n == 1 ? 'wireless router' : 'wireless routers';
      }
      return n == 1 ? type : '${type}s';
    }

    const order = [
      'router',
      'switch',
      'pc',
      'server',
      'firewall',
      'wireless',
      'laptop',
      'printer',
      'phone',
      'cloud',
      'modem',
    ];
    final chips = <Widget>[];
    final shown = <String>{};
    void addCountChip(String type) {
      final n = counts[type];
      if (n == null || n <= 0 || !shown.add(type)) return;
      chips.add(_slotChip(
        '$n ${unit(type, n)}',
        // TAP TO FIX. A count is the slot the parser most often gets wrong
        // and the one a user most wants to change, and the correction is
        // the clearest learning signal there is: their words, what it
        // became, no re-typed English in between.
        onTap: () => _fixSlot(
          messageIndex: index,
          slot: 'count:$type',
          label: unit(type, n),
          value: '$n',
        ),
      ));
    }

    for (final t in order) {
      addCountChip(t);
    }
    for (final t in counts.keys.toList()..sort()) {
      addCountChip(t);
    }
    for (final v in intent.vlans) {
      chips.add(_slotChip(
        'VLAN $v',
        accent: true,
        onTap: () => _fixSlot(
          messageIndex: index,
          slot: 'vlan:$v',
          label: 'VLAN $v',
          value: '$v',
        ),
      ));
    }
    // Always shown, unlike before: a slot the card does not display is a
    // slot the user cannot correct, and a default routing choice is exactly
    // the kind of thing people want to argue with.
    chips.add(_slotChip(
      intent.routing.toUpperCase(),
      accent: intent.routing != 'static',
      onTap: () => _fixSlot(
        messageIndex: index,
        slot: 'routing',
        label: 'routing protocol',
        value: intent.routing,
      ),
    ));

    final questions = intent.questions.take(3).toList();
    final pct = (intent.confidence * 100).round();
    // How this very message was read: kind of turn, corrections found, and
    // whether the words pointed at a saved file - with the excerpts they
    // came from, so the card explains itself, not just the plan.
    final reading = MessageUnderstanding.read(
      text: _messages[index].text,
      parsed: intent,
    );

    // WHAT THIS TURN CHANGED. The count chips describe the standing plan; on
    // their own they cannot tell "add the AAA server" from "ok, build it",
    // and a request the planner could not apply used to look identical to one
    // it did. The delta is named here, and a turn that changed nothing says
    // so rather than leaving the user to guess.
    final hadStanding =
        _previousIntent != null && _previousIntent!.nodes.isNotEmpty;
    final delta = NetworkIntent.planChangeSummary(_previousIntent, intent);
    final changeLine = delta.isNotEmpty
        ? 'Changed by this message: $delta.'
        : hadStanding
        ? 'No count, routing or security change was applied by this '
              'message - the standing lab stands as it was.'
        : '';

    // The roles the plan actually carries, so a named server role is visible
    // as data instead of only being mentioned in the chat text.
    final roleChips = <String>[
      for (final n in intent.nodes)
        for (final s in n.services)
          if (s.trim().isNotEmpty) '${n.name}: ${s.toUpperCase()}',
      if (intent.security.aaa)
        'AAA (${intent.security.aaaProtocol.toUpperCase()})'
            '${intent.security.aaaServer == null ? '' : ' on ${intent.security.aaaServer}'}',
    ];

    return Padding(
      padding: const EdgeInsets.only(top: AppTheme.s6),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: AppTheme.readingMeasure),
        child: Container(
          padding: const EdgeInsets.all(AppTheme.s12),
          decoration: BoxDecoration(
            color: AppPalette.neutralFill(scheme),
            borderRadius: BorderRadius.circular(AppTheme.rMd),
            border: Border.all(color: AppPalette.accentBorder(scheme)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.auto_awesome_outlined,
                    size: 14,
                    color: scheme.primary,
                  ),
                  const SizedBox(width: AppTheme.s6),
                  Text(
                    'Understood',
                    style: theme.textTheme.labelMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: scheme.primary,
                      letterSpacing: 0.2,
                    ),
                  ),
                  const SizedBox(width: AppTheme.s8),
                  Tooltip(
                    message: 'How sure the offline parser is of this plan',
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppTheme.s6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: scheme.surfaceContainerHighest.withValues(
                          alpha: 0.6,
                        ),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        '$pct%',
                        style: theme.textTheme.labelSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              if (chips.isNotEmpty) ...[
                const SizedBox(height: AppTheme.s8),
                Wrap(
                  spacing: AppTheme.s6,
                  runSpacing: AppTheme.s6,
                  children: chips,
                ),
              ],
              // The confirmation for the last tap-to-fix, so a correction is
              // never silent: what it became is said in the card the user
              // just argued with.
              if (_slotFixNote != null && _slotFixNote!.isNotEmpty) ...[
                const SizedBox(height: AppTheme.s6),
                Text(
                  _slotFixNote!,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.primary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
              if (roleChips.isNotEmpty) ...[
                const SizedBox(height: AppTheme.s8),
                Wrap(
                  spacing: AppTheme.s6,
                  runSpacing: AppTheme.s6,
                  children: [
                    for (final role in roleChips) _slotChip(role, accent: true),
                  ],
                ),
              ],
              if (changeLine.isNotEmpty) ...[
                const SizedBox(height: AppTheme.s8),
                Text(
                  changeLine,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
              if (reading.why.isNotEmpty) ...[
                const SizedBox(height: AppTheme.s8),
                Text(
                  'Read as: ${reading.why}',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
              if (reading.corrections.isNotEmpty) ...[
                const SizedBox(height: AppTheme.s4),
                Text(
                  'Corrections read: ${reading.corrections.take(3).map((c) => '"${c.excerpt}"').join(', ')}',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
              if (reading.reference != null) ...[
                const SizedBox(height: AppTheme.s4),
                Text(
                  'Points at the file: "${reading.reference!.excerpt}"',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
              if (questions.isNotEmpty) ...[
                const SizedBox(height: AppTheme.s10),
                Text(
                  'Worth confirming:',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: AppTheme.s6),
                Wrap(
                  spacing: AppTheme.s6,
                  runSpacing: AppTheme.s6,
                  children: [
                    for (final q in questions)
                      _slotChip(
                        q,
                        accent: true,
                        question: true,
                        onTap: () {
                          // Fill, never send: the answer is the user's words
                          // to choose, the same rule the welcome openers use.
                          _input.text = q;
                          _input.selection = TextSelection.collapsed(
                            offset: _input.text.length,
                          );
                          _composerFocus.requestFocus();
                        },
                      ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// One chip in the Understood card. It is tappable when it can be
  /// ANSWERED (a question goes into the composer) or CORRECTED (a count,
  /// a VLAN, the routing protocol opens [_fixSlot]); a chip with no onTap
  /// is there to be read, not argued with.
  Widget _slotChip(
    String text, {
    bool accent = false,
    bool question = false,
    VoidCallback? onTap,
  }) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final color = accent ? scheme.primary : scheme.onSurface;
    final chip = Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppTheme.s10,
        vertical: AppTheme.s6,
      ),
      decoration: BoxDecoration(
        color: accent
            ? AppPalette.accentFill(scheme)
            : scheme.surfaceContainerHighest.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: accent
              ? AppPalette.accentBorder(scheme)
              : scheme.outlineVariant,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (question) ...[
            Icon(Icons.help_outline, size: 13, color: color),
            const SizedBox(width: AppTheme.s4),
          ],
          // Flexible: a question is a sentence, and a sentence in a chip
          // must WRAP inside the card, never overflow it (the wide test
          // font caught this one).
          Flexible(
            child: Text(
              text,
              style: theme.textTheme.labelMedium?.copyWith(
                color: color,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
    if (onTap == null) return chip;
    return InkWell(
      borderRadius: BorderRadius.circular(999),
      onTap: onTap,
      child: chip,
    );
  }

  Widget _bubble(int index) {
    final message = _messages[index];
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isUser = message.isUser;
    final isError = message.isError;
    final stamped = _stamp(message.createdAt);
    final dark = scheme.brightness == Brightness.dark;

    // THE WORDS ARE THE INTERFACE. The assistant's answer sits on the page
    // with no card behind it and no avatar beside it - a long answer reads
    // as a document, not as one tile in a stack of tiles. The user's turn is
    // the only filled thing on screen, because ownership has to be readable
    // in half a second while scrolling.
    final fill = isError
        ? AppPalette.dangerFill(scheme)
        : isUser
        ? AppPalette.neutralFill(scheme)
        : Colors.transparent;
    final ink = isError
        ? AppPalette.danger(scheme)
        : isUser
        ? scheme.onSurface
        : scheme.onSurface;

    // The key is the message object itself, so a search hit can name the
    // exact turn to scroll to: the result and the bubble are the same
    // object, and a rebuilt transcript derives the same key again. Two
    // live keys can never collide - a message object exists once in the
    // list.
    return KeyedSubtree(
      key: GlobalObjectKey(message),
      child: Semantics(
        // A boundary that does NOT absorb its children, so each turn is its
        // OWN node: a screen reader hears "Assistant said" / "You said"
        // first, then the content as its own node. Without this the ownership
        // label merged into one giant node with the whole answer in it - or
        // into the conversation container - and the speaker was never
        // announced.
        container: true,
        explicitChildNodes: true,
        label: isUser ? 'You said' : 'Assistant said',
        child: Padding(
          padding: const EdgeInsets.only(bottom: AppTheme.s14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: isUser
                ? MainAxisAlignment.end
                : MainAxisAlignment.start,
            children: [
              if (!isUser && isError) ...[
                _avatar(isUser, isError),
                const SizedBox(width: AppTheme.s10),
              ],
              Flexible(
                child: Column(
                  crossAxisAlignment: isUser
                      ? CrossAxisAlignment.end
                      : CrossAxisAlignment.start,
                  children: [
                    _messageHeader(isUser, isError, stamped),
                    Container(
                      // ~66 characters at 14px: the reading-optimised measure
                      // (preset 03, Information Architects).
                      constraints: const BoxConstraints(
                        maxWidth: AppTheme.readingMeasure,
                      ),
                      padding: const EdgeInsets.fromLTRB(
                        AppTheme.s14,
                        AppTheme.s12,
                        AppTheme.s14,
                        AppTheme.s12,
                      ),
                      decoration: BoxDecoration(
                        color: fill,
                        borderRadius: BorderRadius.circular(AppTheme.rLg),
                        // A whisper of elevation under an assistant answer on
                        // light surfaces; on dark, separation is contrast.
                        boxShadow: dark || isUser || isError
                            ? null
                            : [
                                BoxShadow(
                                  color: Colors.black.withValues(alpha: 0.05),
                                  blurRadius: 10,
                                  offset: const Offset(0, 2),
                                ),
                              ],
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (message.text.trim().isNotEmpty)
                            // The bubble chooses the ink, so text and fill can
                            // never disagree (the invisible-text bug class).
                            DefaultTextStyle(
                              style:
                                  (theme.textTheme.bodyMedium ??
                                          const TextStyle())
                                      .copyWith(color: ink, height: 1.5),
                              // Headings, bullets, fenced code and tables
                              // render as such; selection is kept so commands
                              // can be copied.
                              child: SelectionArea(
                                child: ChatMarkdownView(
                                  source: message.text,
                                  // A `.pkt` path in the answer is a
                                  // control: tap opens Packet Tracer when
                                  // this machine has it, the built-in
                                  // viewer when it does not.
                                  onFilePathTap: _onPktPathTap,
                                ),
                              ),
                            ),
                          if (message.images.isNotEmpty) ...[
                            const SizedBox(height: AppTheme.s8),
                            Wrap(
                              spacing: AppTheme.s6,
                              runSpacing: AppTheme.s6,
                              children: [
                                for (final image in message.images)
                                  _thumbnail(image),
                              ],
                            ),
                          ],
                          if (message.actions.isNotEmpty) ...[
                            const SizedBox(height: AppTheme.s8),
                            for (var i = 0; i < message.actions.length; i++)
                              if (message.actions[i].kind == 'advice_card')
                                _adviceCard(
                                  index,
                                  i,
                                  message.actions[i],
                                  message.executed.contains(i.toString()),
                                )
                              else if (message.actions[i].kind ==
                                  'brief_card')
                                BriefCardWidget(
                                  key: ValueKey(
                                    'brief-card-$index-$i',
                                  ),
                                  brief: _briefFromPayload(
                                    message.actions[i].payload,
                                  ),
                                )
                              else
                                _actionCard(
                                  index,
                                  i,
                                  message.actions[i],
                                  message.executed.contains(i.toString()),
                                ),
                          ],
                        ],
                      ),
                    ),
                    // The parse of THIS turn, under the turn it belongs to:
                    // what the planner understood, and the questions it still
                    // has - shown before the answer arrives, editable now.
                    if (isUser) _intentUnderstood(index),
                    // The message's own controls, OUTSIDE the bubble: copy,
                    // answer again, remember - quiet utilities under the turn.
                    _messageActions(index, message, isUser),
                    // WHERE an answer came from used to be a small-print
                    // line here; the mode is the app's state, not the
                    // message's, so it lives once in the top bar's AI pill
                    // and no longer repeats under every turn.
                  ],
                ),
              ),
              if (isUser) const SizedBox(width: AppTheme.s10),
              if (isUser) _avatar(isUser, isError),
            ],
          ),
        ),
      ),
    );
  }

  /// Whether this machine can hand a file to the operating system at all:
  /// desktops yes, phones no (there is no Packet Tracer on a phone to open
  /// it with, and no file association to route it).
  bool get _canOpenFiles =>
      !kIsWeb &&
      (Platform.isWindows || Platform.isLinux || Platform.isMacOS);

  /// Hands [path] to the operating system: the file association decides
  /// what opens it - a .pkt lands in Packet Tracer on a machine that has
  /// it. Returns false when the OS could not be asked or refused.
  Future<bool> _openExternally(String path) async {
    try {
      if (Platform.isWindows) {
        // `start` splits its arguments oddly: the empty string is the
        // window-title slot, so a path with spaces stays one argument.
        final r = await Process.run('cmd', ['/c', 'start', '', path]);
        return r.exitCode == 0;
      }
      if (Platform.isMacOS) {
        final r = await Process.run('open', [path]);
        return r.exitCode == 0;
      }
      if (Platform.isLinux) {
        final r = await Process.run('xdg-open', [path]);
        return r.exitCode == 0;
      }
    } catch (_) {
      // A shell that will not cooperate is reported, not thrown: the chat
      // names the folder instead of dying on the user.
    }
    return false;
  }

  /// What tapping a built `.pkt` file does, decided in one place.
  ///
  /// Packet Tracer installed: the OS hands the file over and the real
  /// application opens it. Not installed: the built-in viewer draws the
  /// same network Packet Tracer-style - because the old behaviour on a
  /// machine without the app was a shell dialog asking how to open a file
  /// type it does not know, which reads as the app being broken. Returns
  /// what happened, in the words the chat (or a snackbar) reports.
  Future<({bool handled, String message})> _openPktArtifact(String path) async {
    final name = path.split(RegExp(r'[\\/]')).last;
    bool installed;
    try {
      installed = await PacketTracerLocator.instance.isInstalled();
    } catch (_) {
      installed = false;
    }
    if (installed) {
      final opened = await _openExternally(path);
      return (
        handled: opened,
        message: opened
            ? 'Opening $name in Packet Tracer.'
            : 'I could not hand the file to the operating system. Open it '
                  'from its folder: $path',
      );
    }
    if (!mounted) {
      return (handled: false, message: 'The screen closed before the viewer could open.');
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PktViewerScreen(
          filePath: path,
          intent: _lastIntent,
          positions: _layoutPositions(),
        ),
      ),
    );
    return (
      handled: true,
      message: 'Packet Tracer was not found on this device, so the built-in '
          'viewer is showing $name.',
    );
  }

  /// The as-built canvas positions the engine echoed back with the build
  /// (`layout.positions`, `[x, y]` per device name), as Offsets. Null when
  /// this conversation holds none - the viewer then lets the canvas lay out
  /// the plan itself.
  Map<String, Offset>? _layoutPositions() {
    if (_layout.isEmpty) return null;
    final raw = _layout['positions'];
    if (raw is! Map) return null;
    final out = <String, Offset>{};
    raw.forEach((name, xy) {
      if (xy is List && xy.length >= 2) {
        final x = (xy[0] as num?)?.toDouble();
        final y = (xy[1] as num?)?.toDouble();
        if (x != null && y != null) out[name.toString()] = Offset(x, y);
      }
    });
    return out.isEmpty ? null : out;
  }

  /// The tap on a `.pkt` path inside an answer. Busy-guarded like every
  /// other chat control, and the outcome is said in a snackbar - a tap that
  /// opened something must say what it did.
  Future<void> _onPktPathTap(String path) async {
    if (_busy) return;
    final result = await _openPktArtifact(path);
    if (!mounted || result.message.isEmpty) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        content: Text(result.message),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  /// The small print under an answer naming the backend that produced it
  /// was retired: the AI pill in the top bar carries that state now.
  /// Who said it and when. The name is a label rather than a badge: the
  /// bubble's own alignment already says who spoke, and this is the part a
  /// person scans when they come back to a conversation an hour later.
  Widget _messageHeader(bool isUser, bool isError, String stamped) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: AppTheme.s4, left: 2, right: 2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            isError
                ? 'App'
                : isUser
                ? 'You'
                : 'Assistant',
            style: theme.textTheme.labelSmall?.copyWith(
              fontWeight: FontWeight.w700,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          if (stamped.isNotEmpty) ...[
            const SizedBox(width: AppTheme.s6),
            Text(
              stamped,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant.withValues(
                  alpha: 0.7,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _avatar(bool isUser, bool isError) {
    final scheme = Theme.of(context).colorScheme;
    // The assistant gets the one saturated mark in the conversation - a
    // solid primary disc with a sparkle - so "who can act on the world"
    // is visible without reading a word. The user stays quiet.
    final background = isError
        ? AppPalette.dangerFill(scheme)
        : isUser
        ? scheme.surfaceContainerHighest
        : scheme.primary;
    final foreground = isError
        ? AppPalette.danger(scheme)
        : isUser
        ? scheme.onSurfaceVariant
        : scheme.onPrimary;
    final icon = isError
        ? Icons.report_gmailerrorred_outlined
        : isUser
        ? Icons.person_outline
        : Icons.auto_awesome;
    return Padding(
      padding: const EdgeInsets.only(top: AppTheme.s18),
      child: CircleAvatar(
        radius: 14,
        backgroundColor: background,
        child: Icon(icon, size: 15, color: foreground),
      ),
    );
  }

  /// HH:mm from the stored ISO string, or '' when the row has no timestamp
  /// (older transcripts) - an invented time would be worse than none.
  static String _stamp(String createdAt) => ChatScreen._stamp(createdAt);

  /// The row under a message. Always visible rather than hover-only: hover
  /// does not exist on a tablet, and a control that appears only on hover is a
  /// control half the users never find.
  Widget _messageActions(int index, ChatMessage message, bool isUser) {
    final theme = Theme.of(context);
    final muted = AppPalette.mutedText(theme.colorScheme);
    // A 44x44 TOUCH TARGET, the same one the corrections list uses
    // (lib/widgets/correction_badges.dart:248-252): the row works on a
    // finger, not only on a mouse. shrinkWrap keeps the visible icon at its
    // 14px - the target grows, the button does not - so the row still fits a
    // 320dp phone.
    final style = TextButton.styleFrom(
      foregroundColor: muted,
      padding: const EdgeInsets.symmetric(horizontal: AppTheme.s4),
      minimumSize: const Size(44, 44),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      textStyle: theme.textTheme.labelSmall,
    );
    return Padding(
      padding: const EdgeInsets.only(top: AppTheme.s4),
      child: Row(
        children: [
          TextButton.icon(
            style: style,
            onPressed: () => _copyMessage(message.text),
            icon: const Icon(Icons.copy_all_outlined, size: 14),
            label: const Text('Copy'),
          ),
          if (isUser)
            TextButton.icon(
              style: style,
              onPressed: _busy
                  ? null
                  : () => _editAndResend(index, message),
              icon: const Icon(Icons.edit_outlined, size: 14),
              label: const Text('Edit and resend'),
            )
          else ...[
            TextButton.icon(
              style: style,
              onPressed: _busy ? null : _regenerate,
              icon: const Icon(Icons.refresh, size: 14),
              label: const Text('Answer again'),
            ),
            TextButton.icon(
              style: style,
              onPressed: _busy ? null : () => _rememberFromMessage(message),
              icon: const Icon(Icons.bookmark_add_outlined, size: 14),
              label: const Text('Remember as a rule'),
            ),
          ],
        ],
      ),
    );
  }

  /// "Answer again": the last answer and the turn that produced it are
  /// removed - from the screen AND from the store, or the next reload would
  /// grow the old answer back beneath the new one - and the turn is sent
  /// again as a fresh one, so the new answer takes the old one's place
  /// instead of stacking a duplicate under it.
  ///
  /// Guards: nothing in flight, a user turn to re-ask, and a transcript that
  /// ends on the answer being replaced. The rewrite names only the rows of
  /// the conversation that is open.
  Future<void> _regenerate() async {
    if (_busy) return;
    var lastUser = -1;
    for (var i = _messages.length - 1; i >= 0; i--) {
      if (_messages[i].isUser) {
        lastUser = i;
        break;
      }
    }
    final text = lastUser < 0 ? '' : _messages[lastUser].text;
    if (text.trim().isEmpty) {
      _appendSystem('There is nothing to answer again yet.');
      return;
    }
    if (_messages.last.isUser) {
      _appendSystem('The assistant has not answered that yet.');
      return;
    }
    final conversation = _conversation;
    await _truncateFrom(lastUser, _messages[lastUser]);
    // The rewrite belongs to the conversation it was asked in: if the user
    // switched away while the store was being cut, the re-ask must not land
    // in a different transcript.
    if (!mounted || _conversation != conversation) return;
    _input.text = text;
    await _send();
  }

  /// Remove the turn at [index] and everything after it, on screen and in
  /// the store. The one primitive both history rewrites share: "Answer
  /// again" cuts from the last user turn, "Edit and resend" from the turn
  /// being edited.
  ///
  /// The screen is cut first, then the rows: the store cut is what makes the
  /// rewrite real, but the user must never watch a turn they asked to
  /// disappear flicker back because a query was slow. Anything that existed
  /// to serve the removed tail goes with it - quick replies answered it, the
  /// retry buffer held its text, the activity panel described its work. A
  /// store that cannot follow is said out loud rather than swallowed: a
  /// silent failure here is the old branch resurrecting on the next reload,
  /// which is the exact bug this truncation exists to fix.
  Future<void> _truncateFrom(int index, ChatMessage message) async {
    if (index < 0 || index >= _messages.length) return;
    final conversation = _conversation;
    _cancelReveal();
    setState(() {
      _messages = _messages.sublist(0, index);
      _quickReplies = const [];
      _failedText = null;
      _activity = const [];
    });
    final mem = _memory;
    if (mem == null || !mem.ready) return;
    try {
      await mem.deleteChatFrom(
        conversation,
        fromId: message.id,
        fromCreatedAt: message.createdAt,
        fromRole: message.role,
        fromText: message.text,
      );
    } catch (e) {
      _appendSystem(
        'The transcript could not be rewritten on this device ($e). The '
        'removed turns may come back when this chat is reopened.',
      );
    }
  }

  /// "Edit and resend" supersedes the branch it edits: the turn and
  /// everything after it are gone, the original words go back into the
  /// composer, and sending them starts a fresh turn. Leaving the transcript
  /// truncated when the user changes their mind and never sends is
  /// deliberate - the old branch was superseded the moment they chose to
  /// edit it, and growing it back on reload would undo the edit they asked
  /// for.
  Future<void> _editAndResend(int index, ChatMessage message) async {
    if (_busy || !message.isUser) return;
    if (index < 0 || index >= _messages.length) return;
    await _truncateFrom(index, message);
    if (!mounted) return;
    setState(() {
      _input.text = message.text;
      _input.selection = TextSelection.collapsed(
        offset: _input.text.length,
      );
    });
    _composerFocus.requestFocus();
  }

  /// Stop an in-flight progressive reveal WITHOUT writing its answer down.
  /// [settle] always persists - right when the answer survived (the screen
  /// went away, the next turn arrived), wrong when the turn it belongs to
  /// was just truncated: letting it finish would log the removed answer and
  /// grow the deleted branch straight back into the store.
  void _cancelReveal() {
    _reveal?.cancel();
    _reveal = null;
    _revealFinish = null;
    _revealPersist = null;
  }

  /// "Always use OSPF" typed plainly is a preference stated out loud: it
  /// goes into the same rule store the "Remember as a rule" button writes,
  /// so the planner applies it to every later parse. Gated by the
  /// Learn-automatically setting, and quiet when off or already learned.
  Future<void> _autoTeachPreference(String text) async {
    final settings = _settings;
    if (settings == null || !settings.autoTeach) return;
    if (!PlannerMemoryService.isPreferenceStatement(text)) return;
    final mem = _memory;
    if (mem == null || !mem.ready) return;
    try {
      final trimmed = text.trim();
      final already = (await mem.allRules()).any(
        (r) => r.ruleText.trim().toLowerCase() == trimmed.toLowerCase(),
      );
      if (already) return;
      await mem.addRule(trimmed);
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          content: Text('Learned as a rule: $trimmed'),
          duration: const Duration(seconds: 2),
        ),
      );
    } catch (_) {
      // A rule that fails to save must never cost the turn that stated it.
    }
  }

  /// "This is for the office", "40 users", "I'm a beginner": environment
  /// facts stated in passing, folded into ONE remembered profile instead of
  /// being re-derived per message and forgotten. The advisor falls back to
  /// it whenever a later message leaves a fact unsaid, and the Memory
  /// screen shows and corrects it. Same gates as [_autoTeachPreference] -
  /// Learn-automatically must be on, and a save failure never costs the
  /// turn. Quiet unless something NEW was learned: re-stating a known fact
  /// is not a notification.
  Future<void> _updateEnvironmentProfile(String text) async {
    final settings = _settings;
    if (settings == null || !settings.autoTeach) return;
    final mem = _memory;
    if (mem == null || !mem.ready) return;
    try {
      final merged = EnvironmentProfileService.learnFrom(
        text,
        await mem.environmentProfile(),
      );
      if (merged == null) return;
      await mem.setEnvironmentProfile(merged);
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          content: Text('Noted: ${merged.summaryLine}'),
          duration: const Duration(seconds: 2),
        ),
      );
    } catch (_) {
      // Learning the environment must never cost the turn that stated it.
    }
  }

  // --- the brief conversation ----------------------------------------------

  /// The remembered environment, or null when there is none (or memory is
  /// down). Small, but called from three places that must agree.
  Future<EnvironmentProfile?> _loadEnvironmentProfile() async {
    final mem = _memory;
    if (mem == null || !mem.ready) return null;
    try {
      return await mem.environmentProfile();
    } catch (_) {
      return null;
    }
  }

  /// The questions to ask for the standing plan: critical gaps, minus the
  /// ones this environment has already answered. A remembered answer is
  /// APPLIED to the brief here - which can make the brief ready without
  /// asking anything, at which point this returns an empty list.
  Future<List<ClarificationQuestion>> _clarificationsFor(
    NetworkIntent plan,
    EnvironmentProfile? profile,
  ) async {
    final remembered = <String>{};
    final mem = _memory;
    if (mem != null && mem.ready) {
      for (final id in DesignBrief.slotIds) {
        final fact = await ClarificationService.rememberedAnswer(
          questionId: id,
          profile: profile,
          mem: mem,
        );
        if (fact != null) {
          remembered.add(id);
          _brief = _brief.withFact(id, fact);
          // A remembered answer steers the standing plan too - that is the
          // whole point of remembering it.
          final reconciled = _reconcilePlanWithFact(plan, id, fact);
          if (reconciled != null) {
            _lastIntent = reconciled;
            _state.withIntentJson(
              jsonEncode(reconciled.toJson(includeSecrets: false)),
            );
          }
        }
      }
      _state.briefJson = jsonEncode(_brief.toJson());
    }
    return ClarificationService.neededFor(
      brief: _brief,
      plan: plan,
      profile: profile,
      rememberedQuestionIds: remembered,
    );
  }

  /// Fold a brief answer into the standing plan where the plan can carry
  /// it, so the brief and the lab never disagree at build time: a routing
  /// choice becomes the plan's routing, and a scale answer grows the lab's
  /// PCs to serve it (never shrinks - "25" does not delete devices the user
  /// named). Returns the new plan, or null when nothing changed or the
  /// merge failed (fail-open: the brief stays the source of truth either
  /// way). Segmentation and security remain planner-level decisions in v1.
  NetworkIntent? _reconcilePlanWithFact(
    NetworkIntent? plan,
    String slotId,
    BriefFact fact,
  ) {
    if (plan == null || plan.nodes.isEmpty) return null;
    try {
      if (slotId == DesignBrief.routing &&
          fact.value.isNotEmpty &&
          plan.routing.toLowerCase() != fact.value) {
        return PlannerMemoryService.apply(
          plan,
          rules: const [],
          preferences: {'routing': fact.value},
        );
      }
      if (slotId == DesignBrief.scale) {
        final wanted = int.tryParse(fact.value) ?? 0;
        final pcs = plan.nodes.where((n) => n.type == 'pc').length;
        if (wanted <= 0 || wanted <= pcs) return null;
        final briefText = 'add $wanted pcs';
        final outcome = NetworkIntent.followUp(
          previous: plan,
          previousBrief: _lastBrief,
          brief: briefText,
          parsed: NetworkIntent.parseSimple('clarification', briefText),
          project: plan.projectName,
        );
        return outcome.plan.nodes.length > plan.nodes.length
            ? outcome.plan
            : null;
      }
    } catch (_) {
      return null;
    }
    return null;
  }

  /// Try to resolve the pending clarifications against this message. First
  /// one that resolves wins; null when the message answers none of them.
  Future<({ClarificationQuestion question, BriefFact fact, String raw})?>
      _resolvePendingClarification(String text) async {
    for (final id in _state.pendingQuestionIds) {
      final q = ClarificationService.questionById(id);
      if (q == null) continue;
      final fact = ClarificationService.resolveAnswer(q, text);
      if (fact == null) continue;
      return (question: q, fact: fact, raw: text.trim());
    }
    return null;
  }

  /// Apply an answered clarification: into the brief as a user decision,
  /// and into the clarification memory keyed to this environment - so the
  /// same person is never asked the same question twice - then answer with
  /// the ack (and the next question, or the ready note).
  Future<void> _applyClarificationAnswer(
    ({ClarificationQuestion question, BriefFact fact, String raw}) answered,
  ) async {
    final profile = await _loadEnvironmentProfile();
    _brief = _brief.withFact(
      answered.question.id,
      BriefFact(
        value: answered.fact.value,
        display: answered.fact.display,
        source: 'your answer',
        origin: BriefSource.user,
      ),
    );
    _state.briefJson = jsonEncode(_brief.toJson());
    _state.pendingQuestionIds = const [];
    // The answer is a plan decision where the plan can carry it, not just a
    // card: "OSPF" changes the lab's routing; "40" grows its PC count.
    final reconciled = _reconcilePlanWithFact(
      _lastIntent,
      answered.question.id,
      answered.fact,
    );
    if (reconciled != null) {
      _lastIntent = reconciled;
      _state.withIntentJson(
        jsonEncode(reconciled.toJson(includeSecrets: false)),
      );
    }
    final mem = _memory;
    if (mem != null && mem.ready) {
      try {
        await mem.rememberClarification(
          answered.question.id,
          answered.raw,
          venue: profile?.venue ?? '',
          scale: profile?.scale ?? 0,
        );
      } catch (_) {}
    }
    // What is still open after this answer - remembered answers may fill
    // the rest, in which case the brief is simply ready.
    final clarifying = await _clarificationsFor(
      _lastIntent ?? NetworkIntent(projectName: 'offline-chat'),
      profile,
    );
    _state.pendingQuestionIds = [for (final q in clarifying) q.id];
    final ready = _brief.ready;
    final b = StringBuffer()
      ..writeln(
        '**Got it** - ${DesignBriefService.labelFor(answered.question.id)}: '
        '${answered.fact.display}.',
      );
    if (clarifying.isNotEmpty) {
      b
        ..writeln()
        ..writeln(
          'Still open: ${clarifying.map((q) => q.question).join(' ')}',
        );
    } else {
      // Ready, or the gaps that remain have no question (the planner's safe
      // defaults cover them, and the brief card shows which).
      b
        ..writeln()
        ..writeln(
          ready
              ? 'That fills in everything I need to plan the network. Say '
                    '"build the .pkt" when you want the file, or keep '
                    'adjusting.'
              : 'Nothing else I need to ask - the rest uses the planner\'s '
                    'safe defaults, shown on the brief. Say "build the '
                    '.pkt" when you want the file.',
        );
    }
    final turn = ChatMessage(
      role: 'model',
      text: b.toString().trim(),
      createdAt: DateTime.now().toIso8601String(),
      source: _aiStatus.source,
      actions: [if (_brief.isNotEmpty) _briefCardFor(_brief)],
    );
    if (!mounted) return;
    setState(() {
      _messages = [..._messages, turn];
      _quickReplies = clarifying.isEmpty
          ? ['Build the .pkt']
          : [
              for (final q in clarifying) ...q.quickReplies,
              'Just build it with defaults',
            ];
    });
    _jumpToEnd();
    final store = _memory;
    if (store != null && store.ready) {
      try {
        await store.logChat(turn, conversation: _conversation);
        await store.setSessionState(_conversation, _state.encode());
      } catch (_) {}
    }
    await _refreshConversations();
  }

  /// The user insisting on a build despite open brief slots: "just build
  /// it", "build the .pkt", "go ahead". The planner's safe defaults apply
  /// to what is still open - visible on the brief card - instead of the
  /// app stalling on questions nobody asked for.
  static final RegExp _forcedBuild = RegExp(
    r'\bjust build\b|\bbuild it\b|\bgo ahead\b|\bjust do it\b'
    r'|\bbuild\b[^.]{0,24}\bpkt\b|\bcompile\b|\bbuild now\b',
  );

  static bool _isForcedBuild(String text) =>
      _forcedBuild.hasMatch(text.trim().toLowerCase());

  /// The design brief, as a persisted card action (see `brief_card` in
  /// [ChatAction.supported]).
  ChatAction _briefCardFor(DesignBrief brief) => ChatAction(
    kind: 'brief_card',
    summary: 'Design brief',
    payload: {'brief': brief.toJson()},
  );

  /// Decode a persisted brief card payload; a card that will not decode
  /// renders as nothing rather than crashing the transcript.
  static DesignBrief _briefFromPayload(Map<String, dynamic> payload) {
    try {
      final raw = payload['brief'];
      if (raw is Map) {
        return DesignBrief.fromJson(Map<String, dynamic>.from(raw));
      }
    } catch (_) {}
    return const DesignBrief();
  }

  /// The structured advice answer, as a persisted card action.
  ///
  /// Riding [ChatAction] (allowlisted as `advice_card`) means the card
  /// survives a conversation reopen exactly like a build card does, and the
  /// payload - not a re-parse of the markdown - is what the widget draws.
  ChatAction _adviceCardFor(AdviceAnswer advice) => ChatAction(
    kind: 'advice_card',
    summary: 'Design advice',
    payload: {
      'topic': advice.topic,
      'kind': advice.kind.name,
      'recommendation': advice.recommendation,
      'options': [
        for (final o in advice.options)
          {'label': o.label, 'chooseWhen': o.chooseWhen, 'tradeOff': o.tradeOff},
      ],
      'reasons': advice.reasons,
      'nextStep': advice.nextStep,
      'planBrief': advice.planBrief ?? '',
      'basis': advice.basis,
    },
  );

  /// Store the answer as a rule the planner reads. The value of a correction
  /// is that it changes the next plan, not just this conversation - which is
  /// what the memory already does, so this writes there.
  Future<void> _rememberFromMessage(ChatMessage message) async {    final mem = _memory;
    if (mem == null || !mem.ready) {
      _appendSystem(
        'Memory is not available in this session, so the rule was not saved.',
      );
      return;
    }
    final text = await showDialog<String>(
      context: context,
      builder: (dialogContext) => _RuleDialog(initial: message.text),
    );
    if (text == null || text.trim().isEmpty) return;
    try {
      await mem.addRule(text.trim());
      _appendSystem('Saved as a rule: ${text.trim()}');
    } catch (e) {
      _appendSystem('Could not save that rule: $e');
    }
  }

  Widget _thumbnail(ChatImage image) {
    final file = File(image.path);
    return Tooltip(
      message: '${image.name} ${image.sizeLabel}',
      child: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: file.existsSync()
            ? Image.file(
                file,
                width: 120,
                height: 80,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => _brokenThumb(image),
              )
            : _brokenThumb(image),
      ),
    );
  }

  Widget _brokenThumb(ChatImage image) => Container(
    width: 120,
    height: 80,
    alignment: Alignment.center,
    decoration: BoxDecoration(
      border: Border.all(color: Theme.of(context).dividerColor),
      borderRadius: BorderRadius.circular(6),
    ),
    child: Text(
      'missing\n${image.name}',
      textAlign: TextAlign.center,
      style: const TextStyle(fontSize: 10),
    ),
  );

  /// The advice card: an `advice_card` action draws as the structured card
  /// (recommendation highlighted, options, "Plan this") instead of the
  /// standard approve-gated card. "Plan this" sends the advisor's plan-able
  /// sentence as a normal turn - the planner parses it, the validator gates
  /// it - and marks the card done, the same record [_runAction] keeps.
  Widget _adviceCard(
    int messageIndex,
    int actionIndex,
    ChatAction action,
    bool done,
  ) {
    return AdviceCardWidget(
      key: ValueKey('advice-card-$messageIndex-$actionIndex'),
      payload: action.payload,
      onPlanThis: done
          ? null
          : () {
              final brief = '${action.payload['planBrief'] ?? ''}'.trim();
              if (brief.isEmpty) return;
              _markActionExecuted(messageIndex, actionIndex);
              _sendQuickReply(brief);
            },
    );
  }

  /// Record an action as done without an [_runAction] execution behind it -
  /// "Plan this" runs by sending a turn, not by executing a payload.
  void _markActionExecuted(int messageIndex, int actionIndex) {
    final message = _messages[messageIndex];
    final updated = message.copyWith(executed: [
      ...message.executed,
      actionIndex.toString(),
    ]);
    setState(() {
      _messages = [..._messages];
      _messages[messageIndex] = updated;
    });
    final mem = _memory;
    if (mem != null && mem.ready && message.id != null) {
      mem.updateChat(message.id!, updated).catchError((_) {});
    }
  }

  Widget _actionCard(
    int messageIndex,
    int actionIndex,
    ChatAction action,
    bool done,
  ) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final accent = action.touchesPacketTracer
        ? AppPalette.warning(scheme)
        : scheme.primary;
    // A build card whose plan still carries blocking findings - or whose plan
    // version is no longer the standing one - is withheld here, next to the
    // reason, instead of failing only after the click.
    final blockReason = _buildBlockReason(action);
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(AppTheme.rMd),
        border: Border(left: BorderSide(color: accent, width: 3)),
        boxShadow: [
          BoxShadow(
            color: scheme.outlineVariant.withValues(alpha: 0.55),
            blurRadius: 0,
            spreadRadius: 0.8,
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                action.touchesPacketTracer
                    ? Icons.warning_amber_rounded
                    : Icons.bolt_outlined,
                size: 18,
                color: accent,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  action.label,
                  style: const TextStyle(fontSize: 13, height: 1.35),
                ),
              ),
            ],
          ),
          if (action.touchesPacketTracer)
            Padding(
              padding: const EdgeInsets.only(top: 4, left: 26),
              child: Text(
                'Approving this types into Packet Tracer and is verified on '
                'screen afterwards.',
                style: TextStyle(
                  fontSize: 11,
                  color: AppPalette.warning(scheme),
                ),
              ),
            ),
          _actionPayload(action),
          if (blockReason != null)
            Padding(
              padding: const EdgeInsets.only(top: 6, left: 26),
              child: Text(
                blockReason,
                style: TextStyle(
                  fontSize: 11,
                  height: 1.35,
                  color: AppPalette.danger(scheme),
                ),
              ),
            ),
          const SizedBox(height: 6),
          done
              ? Row(
                  children: [
                    Icon(
                      Icons.check_circle,
                      size: 18,
                      color: AppPalette.success(scheme),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      'Done',
                      style: TextStyle(
                        fontSize: 12,
                        color: AppPalette.success(scheme),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                )
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // THE APPROVAL GATE: nothing is written, exported
                    // or applied until Approve is pressed. Reject is
                    // recorded and has no side effects at all.
                    if (action.kind == 'pkt_fix') ...[
                      TextButton(
                        onPressed: _busy
                            ? null
                            : () => _rejectAction(
                                messageIndex,
                                actionIndex,
                                action,
                              ),
                        child: const Text('Reject'),
                      ),
                      TextButton(
                        onPressed: _busy
                            ? null
                            : () => _modifyAction(
                                messageIndex,
                                actionIndex,
                                action,
                              ),
                        child: const Text('Modify'),
                      ),
                    ],
                    const Spacer(),
                    // A blocked build card is not a dead end any more. The
                    // button used to be disabled and relabelled "Fix the plan
                    // first" - advice with nothing behind it, since the only
                    // way to clear a finding was to retype the whole brief.
                    // It now runs the repair: one tap fixes what can be fixed,
                    // reports what it could not, and answers with a fresh card
                    // stamped with the plan that stands.
                    if (action.kind == 'pkt_generate' && blockReason != null)
                      FilledButton.tonal(
                        onPressed: _busy
                            ? null
                            : () => _sendQuickReply('fix the plan'),
                        child: const Text('Fix the plan'),
                      )
                    else
                      FilledButton(
                        onPressed: _busy
                            ? null
                            : () => _runAction(messageIndex, actionIndex),
                        child: Text(
                          action.kind == 'pkt_generate'
                              ? 'Build .pkt'
                              : 'Approve',
                        ),
                      ),
                  ],
                ),
        ],
      ),
    );
  }

  /// Every field of an action nobody has written a renderer for yet, so an
  /// unknown-but-allowlisted action is still readable before it is approved.
  /// Secret-looking keys are named but never printed.
  static List<String> _genericPayloadLines(ChatAction action) {
    final secretish = RegExp(
      r'(password|secret|psk|token|key)$',
      caseSensitive: false,
    );
    final out = <String>[];
    for (final entry in action.payload.entries) {
      final key = entry.key;
      if (secretish.hasMatch(key)) {
        out.add('$key: (hidden)');
        continue;
      }
      final value = entry.value;
      if (value is Map) {
        out.add('$key:');
        for (final nested in value.entries) {
          out.add('    ${nested.key} = ${nested.value}');
        }
      } else if (value is List) {
        out.add('$key:');
        for (final item in value) {
          out.add('    $item');
        }
      } else {
        out.add('$key = $value');
      }
    }
    return out;
  }

  /// The exact payload, always shown before the button is pressed.
  ///
  /// A one-line label ("type CLI on 2 devices") is not enough to approve
  /// commands with: the entire value of the gate is that a person reads what
  /// will be typed *before* it is typed. Hiding the payload behind an approve
  /// button would make this card a rubber stamp.
  Widget _actionPayload(ChatAction action) {
    final lines = <String>[];
    switch (action.kind) {
      case 'paste_cli':
        final configs = (action.payload['configs'] as Map?) ?? const {};
        configs.forEach((device, body) {
          lines.add('$device:');
          for (final line in body.toString().split('\n')) {
            if (line.trim().isEmpty) continue;
            lines.add('    ${line.trim()}');
          }
        });
        break;
      case 'config_pcs':
        final pcs = (action.payload['pcs'] as Map?) ?? const {};
        pcs.forEach((device, value) {
          if (value is! Map) return;
          final mask = (value['mask'] ?? '').toString().trim();
          final gateway = (value['gw'] ?? '').toString().trim();
          lines.add(
            '$device: ip ${value['ip']}'
            '${mask.isEmpty ? '' : ' / $mask'}'
            '${gateway.isEmpty ? '' : '  gateway $gateway'}',
          );
        });
        break;
      case 'save_rule':
        lines.add((action.payload['rule'] ?? '').toString().trim());
        break;
      case 'save_preference':
        lines.add('${action.payload['key']} = ${action.payload['value']}');
        break;
      case 'run_control':
        lines.add((action.payload['command'] ?? '').toString());
        break;
      case 'open_project':
        lines.add((action.payload['project'] ?? '').toString());
        break;
      case 'pkt_fix':
        final path = (action.payload['path'] ?? '').toString().trim();
        if (path.isNotEmpty) lines.add('file: $path');
        final device = (action.payload['device'] ?? '').toString().trim();
        if (device.isNotEmpty) lines.add('device: $device');
        final finding = (action.payload['finding'] ?? '').toString().trim();
        if (finding.isNotEmpty) lines.add('finding: $finding');
        final cli = action.payload['fix_cli'];
        if (cli is List) {
          for (final command in cli) {
            final c = command.toString().trim();
            if (c.isNotEmpty) lines.add('  $c');
          }
        } else if (cli != null && cli.toString().trim().isNotEmpty) {
          lines.add('  ${cli.toString().trim()}');
        }
        break;
      case 'pkt_undo':
        final entry = (action.payload['entry'] ?? action.payload['id'] ?? '')
            .toString()
            .trim();
        lines.add(
          entry.isEmpty ? 'Undo the last repair' : 'repair entry $entry',
        );
        break;
      case 'pkt_scan':
        final path = (action.payload['path'] ?? '').toString().trim();
        if (path.isNotEmpty) lines.add('read-only scan of $path');
        final name = (action.payload['name'] ?? '').toString().trim();
        if (name.isNotEmpty) lines.add('file: $name');
        break;
      case 'pkt_open':
        lines.add(
          _ptInstalled == false
              ? 'show the network in the built-in viewer '
                    '(Packet Tracer was not found)'
              : 'open the file in Packet Tracer via the operating system',
        );
        break;
      case 'pkt_export':
        final path = (action.payload['path'] ?? '').toString().trim();
        if (path.isNotEmpty) lines.add('save a copy of $path');
        break;
      case 'layout_preview':
        final style = (action.payload['style'] ?? '').toString().trim();
        lines.add(
          style.isEmpty
              ? 'preview of the drawing this plan would be built with'
              : 'preview of the $style drawing',
        );
        break;
      case 'pkt_generate':
        // Rendered from the PAYLOAD the card was written with, never from the
        // plan on screen now. The old version read the live plan, so an old
        // card silently re-described itself as whatever the conversation had
        // become - a card for 17 devices could read "2 device(s), 0 link(s)".
        final plan = _lastIntent;
        final stamped = (action.payload['revision'] ?? '').toString();
        final name = (action.payload['project'] ?? '').toString().trim();
        final devices = (action.payload['devices'] as num?)?.toInt();
        final links = (action.payload['links'] as num?)?.toInt();
        final stale =
            plan != null && stamped.isNotEmpty && stamped != plan.revision;
        // A card that carries no counts describes no plan. Saying "0 device(s)"
        // would be a guess, and quietly substituting the live plan is the bug
        // this whole path exists to prevent, so it is named as unstamped.
        final described = devices != null && links != null;
        if (!described) {
          lines.add(
            'This build card never recorded which plan it was written for, so '
            'it is not buildable and no device or link count is claimed. '
            'Ask me to build the current plan'
            '${plan == null ? '' : ' (${plan.nodes.length} device(s), '
                      '${plan.links.length} link(s), rev ${plan.revision})'}.',
          );
          break;
        }
        final shownName = name.isNotEmpty
            ? name
            : (plan?.projectName.trim() ?? '');
        lines.add(
          'Build "$shownName" from the plan this card was written for: '
          '$devices device(s), $links link(s), target $_target'
          '${stamped.isEmpty ? '' : ', rev $stamped'}.',
        );
        if ((action.payload['mode'] ?? '') == 'new') {
          lines.add('A new file is written; the one already on disk is kept.');
        }
        if (stale) {
          lines.add(
            'The plan has since changed (now rev ${plan.revision}: '
            '${plan.nodes.length} device(s), ${plan.links.length} link(s)). '
            'Build the current plan instead of this card.',
          );
          break;
        }
        // The findings that would be baked into THIS file, so the count on
        // the card and the reason the button is withheld are the same thing.
        final findings = _blockingFindings(plan);
        if (findings.isNotEmpty) {
          lines.add('Not buildable yet - ${findings.length} finding(s):');
          for (final issue in findings.take(6)) {
            lines.add('  [${issue.severity}] ${issue.message}');
          }
          if (findings.length > 6) {
            lines.add('  ... and ${findings.length - 6} more.');
          }
        }
        break;
      case 'pkt_edit':
        final path = (action.payload['path'] ?? '').toString().trim();
        if (path.isNotEmpty) lines.add('Rewrite $path');
        lines.add(
          'The build already on disk is kept as a timestamped backup first.',
        );
        break;
      case 'ledger':
        lines.add('Show the read-only repair ledger.');
        break;
      case 'check_plan':
        final checkName = _lastIntent?.projectName.trim() ?? '';
        lines.add(
          checkName.isEmpty
              ? 'Run the local validator on the current plan (read-only).'
              : 'Run the local validator on "$checkName" (read-only) and '
                    'show the findings.',
        );
        break;
    }
    // Nothing approved on trust: a supported action with no readable payload
    // still states its own fields rather than showing an empty card.
    if (lines.isEmpty) {
      lines.addAll(_genericPayloadLines(action));
    }
    final body = lines.where((line) => line.trim().isNotEmpty).join('\n');
    if (body.isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 8, left: 26),
      padding: const EdgeInsets.all(8),
      constraints: const BoxConstraints(maxHeight: 180),
      decoration: BoxDecoration(
        color: AppPalette.infoFill(scheme),
        borderRadius: BorderRadius.circular(6),
      ),
      child: SingleChildScrollView(
        child: SelectableText(
          body,
          style: TextStyle(
            fontFamily: 'monospace',
            fontSize: 12,
            color: scheme.onSurface,
          ),
        ),
      ),
    );
  }

  /// Re-send the turn that failed, straight from the retry button.
  Future<void> _retry() async {
    final text = _failedText;
    if (text == null || text.trim().isEmpty) return;
    _failedText = null;
    _input.text = text;
    await _send();
  }

  /// What the imported seed can build, shown next to the import action.
  String? _seedHint;

  /// Pick a Packet Tracer save and keep it as this device's template seed.
  ///
  /// This is the step that replaces the whole sidecar template library on a
  /// machine that cannot run the extractor. It happens once: the save is
  /// copied into the app's own documents directory, which on Android is
  /// app-private and needs no runtime permission.
  Future<void> _importSeedPkt() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final picked = await FilePicker.platform.pickFiles(
        type: FileType.any,
        withData: true,
      );
      if (picked == null || picked.files.isEmpty) return;
      final path = picked.files.first.path;
      if (path == null) {
        _appendSystem(
          'That file has no readable path on this device, so it cannot be '
          'used as a seed. Copy it into Downloads first and pick it there.',
        );
        return;
      }
      final dir = await getApplicationDocumentsDirectory();
      final library = OnDevicePktBuilder.installSeed(File(path), dir);
      if (!mounted) return;
      setState(() {
        _seedHint = '${library.devices.length} device template(s): '
            '${(library.kinds.toList()..sort()).join(', ')}';
      });
      final audit = OnDevicePktBuilder.audit(File(path).readAsBytesSync());
      _appendSystem(
        '**Seed imported.** I can now build '
        '${audit.kinds.toList()..sort()}\n\n'
        'The file stays on this device. Use "Build a .pkt on this device" to '
        'compile the current plan.',
      );
    } on OnDeviceBuildError catch (e) {
      _appendSystem(e.message);
    } catch (e) {
      _appendSystem('Could not import that save: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Compile the standing plan into a .pkt on this device.
  ///
  /// The phone's route: no sidecar, no PC, no network. Everything it cannot
  /// do is written into the report rather than left for the user to discover
  /// in Packet Tracer.
  Future<void> _buildOnDevice() async {
    final intent = _lastIntent;
    if (intent == null || intent.nodes.isEmpty) {
      _appendSystem(
        'There is no plan to build yet. Describe the network you want first.',
      );
      return;
    }
    if (_busy) return;
    setState(() => _busy = true);
    try {
      // engineHealthy: false so every failure answers with guidance instead
      // of silently deferring to an engine this screen is not about.
      final result = await _compilePktOnDevice(
        intent: intent,
        drawing: _layout,
        engineHealthy: false,
      );
      if (result == null) {
        _appendSystem(
          'This device has no bundled template library and no imported '
          'seed. Use "Import a seed .pkt" first - one real Packet Tracer '
          'save teaches this device the device models it can build.',
        );
        return;
      }
      _appendSystem(result.text);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Send the last built .pkt out of the app - to a PC over WhatsApp,
  /// Drive, email, whatever the share sheet offers. The build directory is
  /// app-private on Android, so this is the way the file leaves the phone.
  Future<void> _shareArtifact() async {
    final path = _artifactPath.trim();
    if (path.isEmpty) {
      _appendSystem('Nothing to share yet - build a .pkt first.');
      return;
    }
    final file = File(path);
    if (!file.existsSync()) {
      _appendSystem('That file is gone from this device: $path');
      return;
    }
    try {
      final files = <XFile>[XFile(path)];
      // The manifest travels with the file when it exists: it is what
      // tells a generated save apart from a hand-made one on the PC.
      final manifest = File('$path.netbuilder.json');
      if (manifest.existsSync()) files.add(XFile(manifest.path));
      await SharePlus.instance.share(
        ShareParams(
          files: files,
          text: _artifactName.isEmpty ? 'NetBuilder .pkt' : _artifactName,
          title: _artifactName,
        ),
      );
    } catch (e) {
      _appendSystem('Could not open the share sheet: $e');
    }
  }

  /// Share the conversation itself as a markdown document, through the same
  /// system share sheet the .pkt leaves by. The transcript is the record of
  /// what was asked and answered, and it travels as text so it can be pasted
  /// into a ticket or a README exactly as it reads here: message text goes
  /// out verbatim, so fenced code arrives still fenced and runnable.
  ///
  /// No file is written and no network is touched - the share sheet is the
  /// only way out, which is the same boundary the .pkt share keeps.
  Future<void> _shareTranscript() async {
    if (_messages.isEmpty) {
      _appendSystem('Nothing to share yet - this conversation is empty.');
      return;
    }
    // The document itself is [ChatScreen.transcriptMarkdown] - kept pure so
    // the format is pinned by tests, not by a run through the share sheet.
    final text = ChatScreen.transcriptMarkdown(
      _messages,
      conversation: _conversation,
    );
    try {
      await SharePlus.instance.share(
        ShareParams(
          text: text,
          title: 'NetBuilder chat - $_conversation',
        ),
      );
    } catch (e) {
      _appendSystem('Could not open the share sheet: $e');
    }
  }

  /// The context report, opened on demand from the tools sheet.
  ///
  /// This used to be a permanent strip between the transcript and the
  /// composer. It is real information - how much of the window the
  /// conversation has used, and what the last request actually carried - but
  /// as always-on furniture it was the first thing that made the chat look
  /// like a debugging console. Asked for, it is exactly the right answer to
  /// "why did the assistant forget that?".
  void _showContextReport() {
    final plan = ContextBudget.plan(
      history: _messages.where((m) => !m.isError).toList(),
      systemContext: '',
      pendingText: _input.text,
      budgetTokens: _contextTokens,
      runtimeWindowTokens: _window.tokens,
      runtimeWindowSource: _window.source,
      runtimeWindowAssumed: _window.isAssumed,
    );
    final theme = Theme.of(context);
    final report = _requestReport ?? plan.report;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              AppTheme.s16,
              0,
              AppTheme.s16,
              AppTheme.s16,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _sheetHeader(Theme.of(sheetContext), 'Context report'),
                Padding(
                  padding: const EdgeInsets.only(bottom: AppTheme.s8),
                  child: Text(
                    '${_thousands(plan.tokensUsed)} of '
                    '${_thousands(plan.windowTokens)} tokens used'
                    '${plan.summarized ? ' · ${plan.turnsSummarized} earlier '
                        'turn(s) summarized' : ''}.',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
                _contextDetail(theme, report),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// The context inspector: what the last request really carried, and what the
  /// runtime does with it. This is the debugging view the memory bug needed -
  /// it is the difference between "the model forgot" and "the app never sent
  /// it, and here is why".
  Widget _contextDetail(ThemeData theme, RequestReport? report) {
    final scheme = theme.colorScheme;
    final plan = _chat?.lastPlan;
    final lines = <String>[
      if (report != null) report.toText(),
      if (report == null)
        'No request sent yet in this session. The numbers above are the plan '
            'for the message in the box.',
    ];
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: AppPanel(
        dense: true,
        icon: Icons.tune,
        title: 'Context detail',
        children: [
          AppCodeBlock(
            text: lines.join('\n\n'),
            title: 'What the last request carried',
            maxHeight: 260,
          ),
          if (_window.hint.trim().isNotEmpty) ...[
            const SizedBox(height: AppTheme.s10),
            Text(
              _window.hint,
              style: TextStyle(fontSize: 11, color: scheme.tertiary),
            ),
          ],
          if (plan != null && plan.memoriesBlock.isNotEmpty) ...[
            const SizedBox(height: AppTheme.s8),
            Text(
              'Long-term memory injected this turn:\n$_memories',
              style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
            ),
          ],
        ],
      ),
    );
  }

  static String _thousands(int n) {
    final s = n.toString();
    final b = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
      b.write(s[i]);
    }
    return b.toString();
  }

  Widget _composer() {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // The "/" menu: what the app can do, while a command is being
            // typed. It sits closest to the box because it is about the very
            // next keystroke.
            if (_skillMenu.isNotEmpty && !_busy)
              KeyedSubtree(
                key: const ValueKey('skill-menu'),
                child: _skillMenuCard(),
              ),
            // A plan question waiting on an answer - the headcount a brief
            // stated versus the PCs it listed, for one - sits directly above
            // the box as a short list of options, so it is read and answered
            // where the next message would be typed.
            if (_planPrompt != null)
              KeyedSubtree(
                key: const ValueKey('plan-prompt'),
                child: _planPromptCard(_planPrompt!, scheme),
              ),
            // The assistant's own suggestions, as one-tap chips: a chat where
            // the answer is "say \"use ospf\"" should make that a button, not
            // a typing exercise.
            if (_skillMenu.isEmpty && _quickReplies.isNotEmpty && !_busy)
              Padding(
                key: const ValueKey('quick-replies'),
                padding: const EdgeInsets.only(bottom: 6),
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    // Each chip is a suggested NEXT MESSAGE, not a label:
                    // a screen reader hears what tapping it will do.
                    for (final quick in _quickReplies.take(4))
                      Semantics(
                        label: 'Suggested next step: $quick',
                        button: true,
                        onTap: () => _sendQuickReply(quick),
                        child: ExcludeSemantics(
                          child: ActionChip(
                            avatar: const Icon(Icons.bolt_outlined, size: 15),
                            label: Text(
                              quick,
                              style: const TextStyle(fontSize: 12),
                            ),
                            onPressed: () => _sendQuickReply(quick),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            if (_pending.isNotEmpty)
              Padding(
                key: const ValueKey('pending-chips'),
                padding: const EdgeInsets.only(bottom: 6),
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final image in _pending)
                      InputChip(
                        avatar: const Icon(Icons.image_outlined, size: 16),
                        label: Text(
                          image.name,
                          style: const TextStyle(fontSize: 12),
                        ),
                        onDeleted: () => setState(
                          () => _pending = _pending
                              .where((i) => i.path != image.path)
                              .toList(),
                        ),
                      ),
                  ],
                ),
              ),
            // One unified composer capsule - field, attach and send inside a
            // single rounded surface, the way a modern chat input reads. A
            // focus ring (a tinted border plus a soft glow) says "I am
            // listening" the moment the field takes the caret.
            AnimatedBuilder(
              animation: _composerFocus,
              builder: (context, _) {
                final focused = _composerFocus.hasFocus;
                return AnimatedContainer(
                  key: const ValueKey('composer-capsule'),
                  duration: const Duration(milliseconds: 160),
                  curve: Curves.easeOut,
                  padding: const EdgeInsets.fromLTRB(4, 4, 6, 4),
                  decoration: BoxDecoration(
                    color: AppPalette.raised(scheme),
                    borderRadius: BorderRadius.circular(28),
                    border: Border.all(
                      color: focused
                          ? scheme.primary.withValues(alpha: 0.55)
                          : AppPalette.hairline(scheme),
                      width: focused ? 1.4 : 1,
                    ),
                    boxShadow: focused
                        ? [
                            BoxShadow(
                              color: scheme.primary.withValues(alpha: 0.12),
                              blurRadius: 16,
                            ),
                          ]
                        : null,
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  // One media picker, the way a chat app has one: every way
                  // of attaching something lives behind it, and the chat keeps
                  // its space.
                  PopupMenuButton<String>(
                    tooltip: 'Attach',
                    icon: const Icon(Icons.add_circle_outline),
                    onSelected: (value) {
                      if (value == 'image') {
                        _pickImageFiles();
                      } else if (value == 'screenshot') {
                        _attachScreenshot();
                      } else if (value == 'pkt') {
                        _pickPkt();
                      } else if (value == 'paste') {
                        _pasteText();
                      }
                    },
                    itemBuilder: (context) => const [
                      PopupMenuItem(
                        value: 'image',
                        child: ListTile(
                          dense: true,
                          leading: Icon(Icons.add_photo_alternate_outlined),
                          title: Text('Photo or image file'),
                        ),
                      ),
                      PopupMenuItem(
                        value: 'screenshot',
                        child: ListTile(
                          dense: true,
                          leading: Icon(Icons.photo_library_outlined),
                          title: Text('Screenshot from the run'),
                        ),
                      ),
                      PopupMenuItem(
                        value: 'pkt',
                        child: ListTile(
                          dense: true,
                          leading: Icon(Icons.router_outlined),
                          title: Text('Packet Tracer save (.pkt)'),
                        ),
                      ),
                      PopupMenuItem(
                        value: 'paste',
                        child: ListTile(
                          dense: true,
                          leading: Icon(Icons.content_paste),
                          title: Text('Paste clipboard text'),
                        ),
                      ),
                    ],
                  ),
                  Expanded(
                    // ENTER SENDS, SHIFT+ENTER ADDS A LINE.  A
                    // CallbackShortcuts sits closer to the field than the
                    // app-wide text-editing shortcuts, so it wins for a
                    // bare Enter while Shift+Enter falls through to the
                    // default newline.  TextInputAction.send also makes an
                    // on-screen Android keyboard show a Send key.
                    child: CallbackShortcuts(
                      bindings: <ShortcutActivator, VoidCallback>{
                        const SingleActivator(LogicalKeyboardKey.enter): _send,
                        const SingleActivator(LogicalKeyboardKey.numpadEnter):
                            _send,
                      },
                      child: TextField(
                        controller: _input,
                        focusNode: _composerFocus,
                        // NEVER DISABLED WHILE THE ASSISTANT ANSWERS. The box
                        // used to lock the moment a turn started, so a thought
                        // that arrived mid-answer had to be remembered by the
                        // user instead of written down. A disabled field also
                        // swallows the caret and the Android keyboard, which
                        // reads as "the app is broken" rather than "busy".
                        autofocus: true,
                        minLines: 1,
                        maxLines: 6,
                        textInputAction: TextInputAction.send,
                        decoration: InputDecoration(
                          // labelText gives the field a real accessible
                          // name; the hint teaches the shortcuts.
                          labelText: 'Message',
                          hintText:
                              'Ask a question, or describe what to do '
                              '(Enter sends - Shift+Enter = new line)',
                          // The capsule IS the field's surface: the fill and
                          // outline are removed so the input melts into it.
                          filled: false,
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                        ),
                        onSubmitted: (_) => _send(),
                      ),
                    ),
                  ),
                  // Everything else the app can do, labelled, in one sheet.
                  IconButton(
                    tooltip: 'Tools: run, capture, and integrations',
                    icon: const Icon(Icons.tune),
                    onPressed: _busy ? null : _openTools,
                  ),
                  const SizedBox(width: 2),
                  // The send button answers the composer: an empty box gets
                  // a quiet button, a written message gets the filled,
                  // glowing one. Driven by the controller, so only the
                  // button rebuilds on each keystroke - never the
                  // transcript.
                  ValueListenableBuilder<TextEditingValue>(
                    valueListenable: _input,
                    builder: (context, value, _) {
                      final hasText = value.text.trim().isNotEmpty;
                      return AnimatedContainer(
                        duration: const Duration(milliseconds: 160),
                        curve: Curves.easeOut,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: _busy || hasText
                              ? scheme.primary
                              : scheme.surfaceContainerHighest,
                          boxShadow: _busy || hasText
                              ? [
                                  BoxShadow(
                                    color: scheme.primary.withValues(
                                      alpha: 0.30,
                                    ),
                                    blurRadius: 8,
                                    offset: const Offset(0, 2),
                                  ),
                                ]
                              : null,
                        ),
                        child: IconButton.filled(
                          tooltip: _busy ? 'Stop generating' : 'Send',
                          style: IconButton.styleFrom(
                            backgroundColor: Colors.transparent,
                            foregroundColor: _busy || hasText
                                ? scheme.onPrimary
                                : scheme.onSurfaceVariant,
                            elevation: 0,
                          ),
                          icon: _busy
                              ? const Icon(Icons.stop)
                              : const Icon(Icons.send),
                          onPressed: _busy
                              ? _cancelGeneration
                              : (_input.text.trim().isEmpty
                                    ? null
                                    : _send),
                        ),
                      );
                    },
                  ),
                  ],
                ),
              );
            },
          ),
          ],
        ),
      ),
    );
  }
}

/// "The assistant is working": three dots that breathe, next to the same
/// avatar an answer will use, so the wait is visibly the assistant's turn.
class _TypingBubble extends StatefulWidget {
  const _TypingBubble();

  @override
  State<_TypingBubble> createState() => _TypingBubbleState();
}

class _TypingBubbleState extends State<_TypingBubble>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // The three breathing dots say "the assistant is working" only to the
    // eye. A screen reader gets the same sentence.
    return Semantics(
      container: true,
      label: 'The assistant is answering',
      liveRegion: true,
      child: ExcludeSemantics(
        child: Padding(
          padding: const EdgeInsets.only(bottom: AppTheme.s14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: AppTheme.s18),
                child: CircleAvatar(
                  radius: 14,
                  backgroundColor: theme.colorScheme.surfaceContainerHighest,
                  child: Icon(
                    Icons.smart_toy_outlined,
                    size: 15,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              const SizedBox(width: AppTheme.s8),
              Padding(
                padding: const EdgeInsets.only(top: AppTheme.s16),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppTheme.s12,
                    vertical: AppTheme.s10,
                  ),
                  decoration: BoxDecoration(
                    color: AppPalette.neutralFill(theme.colorScheme),
                    borderRadius: BorderRadius.circular(AppTheme.rLg),
                    border: Border.all(
                      color: AppPalette.hairline(theme.colorScheme),
                    ),
                  ),
                  child: AnimatedBuilder(
                    animation: _controller,
                    builder: (context, _) => Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (var i = 0; i < 3; i++) ...[
                          if (i > 0) const SizedBox(width: AppTheme.s4),
                          Opacity(
                            // Each dot peaks a third of a cycle later than the
                            // last: the pulse reads as motion, not as a blink.
                            opacity:
                                0.3 +
                                0.7 *
                                    (1 -
                                            (((_controller.value + i / 3) % 1) -
                                                        0.5)
                                                    .abs() /
                                                0.5)
                                        .clamp(0, 1),
                            child: Container(
                              width: 7,
                              height: 7,
                              decoration: BoxDecoration(
                                color: theme.colorScheme.onSurfaceVariant,
                                shape: BoxShape.circle,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The pill that appears when the transcript is scrolled away from the
/// newest message. It says how much is waiting, because "jump to latest"
/// does not tell you whether it is worth tapping.
class _JumpToLatest extends StatelessWidget {
  final int unseen;
  final VoidCallback onTap;

  const _JumpToLatest({required this.unseen, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      elevation: 2,
      color: theme.colorScheme.inverseSurface,
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppTheme.s14,
            vertical: AppTheme.s8,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (unseen > 0) ...[
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppTheme.s6,
                    vertical: 1,
                  ),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.inversePrimary,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    '$unseen',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onInverseSurface,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(width: AppTheme.s6),
              ],
              Text(
                unseen > 0 ? 'new' : 'Latest',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.onInverseSurface,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: AppTheme.s4),
              Icon(
                Icons.arrow_downward,
                size: 14,
                color: theme.colorScheme.onInverseSurface,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The dialog behind "Remember as a rule": the text is editable before it is
/// saved, because an answer is prose and a rule has to be an instruction the
/// planner can actually follow.
class _RuleDialog extends StatefulWidget {
  final String initial;

  const _RuleDialog({required this.initial});

  @override
  State<_RuleDialog> createState() => _RuleDialogState();
}

class _RuleDialogState extends State<_RuleDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: _distil(widget.initial),
  );

  /// Keep the first sentence or two: a rule is read by the planner on every
  /// turn, so it has to be short enough to be worth its tokens.
  static String _distil(String raw) {
    final text = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (text.length <= 240) return text;
    final cut = text.substring(0, 240);
    final stop = cut.lastIndexOf('. ');
    return stop > 40 ? cut.substring(0, stop + 1) : '$cut...';
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      icon: const Icon(Icons.bookmark_add_outlined),
      title: const Text('Remember this as a rule'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Rules are read before every plan this app makes, so the next '
              'build already follows it. Edit it into one instruction.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: AppTheme.s12),
            TextField(
              controller: _controller,
              autofocus: true,
              minLines: 2,
              maxLines: 5,
              decoration: const InputDecoration(
                labelText: 'The rule',
                hintText:
                    'Always use /30 between routers and document the link',
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_controller.text),
          child: const Text('Save rule'),
        ),
      ],
    );
  }
}

/// The in-conversation search sheet: a field, the hits, nothing else.
///
/// Hits match message text only - tool cards and attachments are not prose
/// to search - and each hit shows the line it was found on, so picking the
/// right one is a reading decision, not a guess between timestamps.
class _ConversationSearch extends StatefulWidget {
  final List<ChatMessage> messages;
  final ValueChanged<ChatMessage> onOpen;

  const _ConversationSearch({required this.messages, required this.onOpen});

  @override
  State<_ConversationSearch> createState() => _ConversationSearchState();
}

class _ConversationSearchState extends State<_ConversationSearch> {
  final _field = TextEditingController();

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  /// The turns whose text contains the query, oldest first. An empty query
  /// matches nothing: an empty hit list is the honest answer to an empty box.
  static List<ChatMessage> matches(
    List<ChatMessage> messages,
    String query,
  ) {
    final needle = query.trim().toLowerCase();
    if (needle.isEmpty) return const [];
    return [
      for (final message in messages)
        if (message.text.toLowerCase().contains(needle)) message,
    ].take(50).toList();
  }

  /// A one-to-two-line window around the first hit, whitespace flattened so
  /// a hit inside a wrapped paragraph reads as one line of context instead
  /// of a mangled block.
  static String snippet(String text, String query) {
    final flat = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    final needle = query.trim().toLowerCase();
    final at = flat.toLowerCase().indexOf(needle);
    if (at < 0) {
      return flat.length <= 120 ? flat : '${flat.substring(0, 120)}...';
    }
    const window = 60;
    // clamp answers a num; substring wants ints.
    final start = (at - window / 3).floor().clamp(0, flat.length).toInt();
    final end = (at + needle.length + window).clamp(0, flat.length).toInt();
    return '${start > 0 ? '...' : ''}${flat.substring(start, end)}'
        '${end < flat.length ? '...' : ''}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hits = matches(widget.messages, _field.text);
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 480),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                child: TextField(
                  controller: _field,
                  autofocus: true,
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search, size: 20),
                    hintText: 'Search this conversation',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ),
              const Divider(height: 1),
              if (hits.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    _field.text.trim().isEmpty
                        ? 'Type to search the messages in this conversation.'
                        : 'No messages in this conversation match that.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                )
              else
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      for (final message in hits)
                        ListTile(
                          dense: true,
                          leading: Icon(
                            message.isUser
                                ? Icons.person_outline
                                : Icons.auto_awesome,
                            size: 18,
                          ),
                          title: Text(
                            snippet(message.text, _field.text),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            '${message.isUser ? 'You' : 'Assistant'}'
                            '${_ChatScreenState._stamp(message.createdAt).isEmpty ? '' : ' - ${_ChatScreenState._stamp(message.createdAt)}'}',
                            style: theme.textTheme.labelSmall,
                          ),
                          onTap: () => widget.onOpen(message),
                        ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The pieces of one request, kept apart so the context builder can allocate
/// and report them separately.
class _ContextParts {
  /// The app's instructions and rules (the system prompt proper).
  final String system;

  /// The live network: project, the plan on the table, the run state.
  final String network;

  /// Layer 2: the structured state of this conversation.
  final String session;

  /// Layer 3: relevant records of past sessions in this install.
  final String memories;

  /// The persisted summary of turns that no longer fit (layer 1's overflow).
  final String summary;

  const _ContextParts({
    required this.system,
    required this.network,
    required this.session,
    required this.memories,
    required this.summary,
  });
}

/// One field change a chat action is about to make, awaiting its old value.
class _PendingChange {
  final String device;
  final String interface;
  final String field;
  final String newValue;

  const _PendingChange({
    required this.device,
    required this.interface,
    required this.field,
    required this.newValue,
  });
}


/// The prompt behind a tap-to-fix chip: one field carrying the value that is
/// wrong, and the two ways out.
///
/// It owns its own controller rather than borrowing one from the caller:
/// the dialog route keeps animating - and keeps listening to its field -
/// after [showDialog] hands the result back, so a controller disposed by the
/// caller is a controller used after dispose. The widget test caught that.
class _SlotFixDialog extends StatefulWidget {
  const _SlotFixDialog({required this.label, required this.value});

  final String label;
  final String value;

  @override
  State<_SlotFixDialog> createState() => _SlotFixDialogState();
}

class _SlotFixDialogState extends State<_SlotFixDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.value);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Fix the ${widget.label}'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: InputDecoration(
          labelText: widget.label,
          hintText: widget.value,
        ),
        onSubmitted: (v) => Navigator.of(context).pop(v),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_controller.text),
          child: const Text('Fix it'),
        ),
      ],
    );
  }
}
